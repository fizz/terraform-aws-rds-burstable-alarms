data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_db_instance" "this" {
  db_instance_identifier = var.db_instance_identifier
}

# RDS classes are EC2 types with a "db." prefix, so EC2 reports their memory.
data "aws_ec2_instance_type" "this" {
  instance_type = trimprefix(data.aws_db_instance.this.db_instance_class, "db.")
}

locals {
  id        = var.db_instance_identifier
  class     = trimprefix(data.aws_db_instance.this.db_instance_class, "db.")
  family    = split(".", local.class)[0]
  size      = split(".", local.class)[1]
  memory    = data.aws_ec2_instance_type.this.memory_size * 1024 * 1024
  topic_arn = var.alarm_topic_arn != null ? var.alarm_topic_arn : aws_sns_topic.alarms[0].arn
  dimension = { DBInstanceIdentifier = local.id }

  # Seconds per evaluation period. A period shorter than a metric's reporting interval
  # leaves most periods empty, and an empty period counts as healthy.
  one_minute  = 60
  five_minute = 300
  one_hour    = 3600

  # CPU credits a burstable class earns per hour. It banks at most 24 hours of them.
  # AWS does not publish these through an API.
  credits_per_hour = {
    nano = 6, micro = 12, small = 24, medium = 24, large = 36, xlarge = 96, "2xlarge" = 192
  }
  burstable   = contains(["t3", "t4g"], local.family) && contains(keys(local.credits_per_hour), local.size)
  max_credits = local.burstable ? local.credits_per_hour[local.size] * 24 : 0

  # Free memory below this is the point where the class is in trouble.
  memory_floor = floor(local.memory * var.freeable_memory_percent / 100)

  # Balances that drain: what a full one is worth, in the metric's own unit. EBS and gp2
  # balances are percents, CPU credits are a count that depends on the class.
  balances = merge(
    {
      ebs-byte-balance = {
        metric = "EBSByteBalance%"
        full   = 100
        unit   = "%"
        name   = "The instance's EBS throughput burst"
        note   = "Swapping drains it."
      }
      ebs-io-balance = {
        metric = "EBSIOBalance%"
        full   = 100
        unit   = "%"
        name   = "The instance's EBS I/O burst"
        note   = ""
      }
    },
    data.aws_db_instance.this.storage_type == "gp2" ? {
      storage-burst-balance = {
        metric = "BurstBalance"
        full   = 100
        unit   = "%"
        name   = "The gp2 volume's I/O burst"
        note   = ""
      }
    } : {},
    local.burstable ? {
      cpu-credit-balance = {
        metric = "CPUCreditBalance"
        full   = local.max_credits
        unit   = " credits"
        name   = "The CPU credit balance"
        note   = "A ${data.aws_db_instance.this.db_instance_class} can bank ${local.max_credits}."
      }
    } : {},
  )

  # A balance at or below 1% of full is spent.
  empty = { for k, b in local.balances : k => b.full / 100 }

  # One alarm for each warning. A warning over an hour projects the hour's rate, because one
  # 5-minute change carried that far is noise. It fires after the hour's point is in.
  warnings = merge([
    for k, b in local.balances : {
      for m in var.minutes_of_warning : "${k}-${m}m" => {
        balance = k
        minutes = m
        period  = m > 60 ? local.one_hour : local.five_minute
      }
    }
  ]...)

  metric_alarms = merge(
    {
      for k, b in local.balances : "${k}-empty" => {
        metric      = b.metric
        period      = local.five_minute
        operator    = "LessThanOrEqualToThreshold"
        threshold   = local.empty[k]
        description = trimspace("${b.name} is spent (${local.empty[k]}${b.unit} or less). ${b.note}")
      }
    },
    {
      freeable-memory = {
        metric      = "FreeableMemory"
        period      = local.one_minute
        operator    = "LessThanThreshold"
        threshold   = local.memory_floor
        description = "Free memory is below ${var.freeable_memory_percent}% of ${data.aws_db_instance.this.db_instance_class}. Each connection holds memory, and a burstable instance can run out of memory long before it runs out of connections."
      }
    },
    var.max_connections != null ? {
      connections = {
        metric      = "DatabaseConnections"
        period      = local.one_minute
        operator    = "GreaterThanThreshold"
        threshold   = floor(var.max_connections * var.connections_percent / 100)
        description = "Connections are above ${var.connections_percent}% of max_connections (${var.max_connections})."
      }
    } : {},
  )

  # Alarms on metric math: the input metrics by id, and one expression over them by id.
  math_alarms = merge(
    {
      for key, w in local.warnings : key => {
        period    = w.period
        operator  = "LessThanOrEqualToThreshold"
        threshold = local.empty[w.balance]
        metrics   = { balance = { metric = local.balances[w.balance].metric, stat = "Minimum" } }

        # Where the balance will be in that many minutes at its present rate, which RATE
        # gives per second. Measured with GetMetricData: a metric that is never reported gives
        # no points, a period without a balance gives none, and a balance without a rate is
        # itself. Keep FILL and division out. FILL gives a metric that is never reported a
        # full series of points, an operation between two series counts the missing balance as
        # 0, and a 0 here pages.
        expression  = { projected = "balance + RATE(balance) * ${w.minutes * 60}" }
        description = trimspace("${local.balances[w.balance].name} will be spent (${local.empty[w.balance]}${local.balances[w.balance].unit} or less) within ${w.minutes} minutes at its present rate, or is spent now. ${local.balances[w.balance].note}")
      }
    },
    {
      swap-usage = {
        period    = local.five_minute
        operator  = "GreaterThanOrEqualToThreshold"
        threshold = 1
        metrics = {
          # The maximum, so memory was under the floor for the whole period.
          free = { metric = "FreeableMemory", stat = "Maximum" }
          swap = { metric = "SwapUsage", stat = "Maximum" }
        }
        expression  = { swapping = "IF(free < ${local.memory_floor} AND RATE(swap) > 0, 1, 0)" }
        description = "Swap is growing while free memory is below ${var.freeable_memory_percent}% of ${data.aws_db_instance.this.db_instance_class}, so the instance is short of memory now."
      }

      # Two resources going at once, over the hour: the low of EBS and the high of swap. The
      # limits come from two incidents and were not tuned on quiet days.
      ebs-falls-while-swap-grows = {
        period    = local.one_hour
        operator  = "GreaterThanOrEqualToThreshold"
        threshold = 1
        metrics = {
          ebs  = { metric = "EBSByteBalance%", stat = "Minimum" }
          swap = { metric = "SwapUsage", stat = "Maximum" }
        }
        expression  = { together = "IF(RATE(ebs) * 3600 < -10 AND RATE(swap) * 3600 > 25000000, 1, 0)" }
        description = "The EBS throughput burst fell by more than 10 points in an hour while swap grew by more than 25 MB, so the instance is losing more than one resource."
      }
    },
  )

  alarms  = merge(local.metric_alarms, local.math_alarms)
  is_math = { for k in keys(local.alarms) : k => contains(keys(local.math_alarms), k) }
}

resource "aws_sns_topic" "alarms" {
  count = var.alarm_topic_arn == null ? 1 : 0

  name = "${local.id}-rds-alarms"
  tags = var.tags
}

resource "aws_sns_topic_policy" "alarms" {
  count = var.alarm_topic_arn == null ? 1 : 0

  arn    = aws_sns_topic.alarms[0].arn
  policy = data.aws_iam_policy_document.topic.json
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AccountOwns"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes"]
    resources = ["arn:${data.aws_partition.current.partition}:sns:*:${data.aws_caller_identity.current.account_id}:${local.id}-rds-alarms"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AlarmsAndRdsEventsPublish"
    actions   = ["sns:Publish"]
    resources = ["arn:${data.aws_partition.current.partition}:sns:*:${data.aws_caller_identity.current.account_id}:${local.id}-rds-alarms"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.alarm_topic_arn == null ? toset(var.alarm_emails) : toset([])

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.id}-${each.key}"
  alarm_description   = each.value.description
  evaluation_periods  = max(1, ceil(var.evaluation_minutes * 60 / each.value.period))
  datapoints_to_alarm = max(1, ceil(var.evaluation_minutes * 60 / each.value.period))
  comparison_operator = each.value.operator
  threshold           = each.value.threshold

  # One metric compared with the threshold. Null on a math alarm.
  namespace   = local.is_math[each.key] ? null : "AWS/RDS"
  metric_name = local.is_math[each.key] ? null : each.value.metric
  dimensions  = local.is_math[each.key] ? null : local.dimension
  period      = local.is_math[each.key] ? null : each.value.period
  statistic   = local.is_math[each.key] ? null : (startswith(each.value.operator, "LessThan") ? "Minimum" : "Maximum")

  dynamic "metric_query" {
    for_each = local.is_math[each.key] ? each.value.metrics : {}

    content {
      id          = metric_query.key
      return_data = false

      metric {
        namespace   = "AWS/RDS"
        metric_name = metric_query.value.metric
        dimensions  = local.dimension
        stat        = metric_query.value.stat
        period      = each.value.period
      }
    }
  }

  dynamic "metric_query" {
    for_each = local.is_math[each.key] ? each.value.expression : {}

    content {
      id          = metric_query.key
      expression  = metric_query.value
      return_data = true
    }
  }

  # A metric the class or volume does not report must not page anyone.
  treat_missing_data = "notBreaching"

  # False creates the alarms silent, so they can settle before they notify anyone. Enabling
  # them later sends nothing by itself, because no alarm changes state.
  actions_enabled = var.actions_enabled

  alarm_actions = [local.topic_arn]
  ok_actions    = [local.topic_arn]
  tags          = var.tags
}

resource "aws_db_event_subscription" "this" {
  name             = "${local.id}-rds-events"
  sns_topic        = local.topic_arn
  source_type      = "db-instance"
  source_ids       = [local.id]
  event_categories = var.event_categories
  tags             = var.tags
}
