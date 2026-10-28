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
  period    = 60
  dimension = { DBInstanceIdentifier = local.id }

  # CPU credits a burstable class earns per hour. It banks at most 24 hours of them.
  # AWS does not publish these through an API.
  credits_per_hour = {
    nano = 6, micro = 12, small = 24, medium = 24, large = 36, xlarge = 96, "2xlarge" = 192
  }
  burstable   = contains(["t3", "t4g"], local.family) && contains(keys(local.credits_per_hour), local.size)
  max_credits = local.burstable ? local.credits_per_hour[local.size] * 24 : 0

  alarms = merge(
    {
      freeable-memory = {
        metric      = "FreeableMemory"
        operator    = "LessThanThreshold"
        threshold   = floor(local.memory * var.freeable_memory_percent / 100)
        description = "Free memory is below ${var.freeable_memory_percent}% of ${data.aws_db_instance.this.db_instance_class}. Each connection holds memory, and a small instance runs out of memory long before it runs out of connections."
      }
      swap-usage = {
        metric      = "SwapUsage"
        operator    = "GreaterThanThreshold"
        threshold   = var.swap_usage_bytes
        description = "The instance is swapping, so it is already short of memory."
      }
      ebs-byte-balance = {
        metric      = "EBSByteBalance%"
        operator    = "LessThanThreshold"
        threshold   = var.burst_balance_percent
        description = "The instance's EBS throughput burst is nearly spent. Swapping drains it."
      }
      ebs-io-balance = {
        metric      = "EBSIOBalance%"
        operator    = "LessThanThreshold"
        threshold   = var.burst_balance_percent
        description = "The instance's EBS I/O burst is nearly spent."
      }
      storage-burst-balance = {
        metric      = "BurstBalance"
        operator    = "LessThanThreshold"
        threshold   = var.burst_balance_percent
        description = "The gp2 volume's I/O burst is nearly spent."
      }
    },
    local.burstable ? {
      cpu-credit-balance = {
        metric      = "CPUCreditBalance"
        operator    = "LessThanThreshold"
        threshold   = floor(local.max_credits * var.cpu_credit_percent / 100)
        description = "CPU credits are below ${var.cpu_credit_percent}% of the ${local.max_credits} a ${data.aws_db_instance.this.db_instance_class} can bank."
      }
    } : {},
    var.max_connections != null ? {
      connections = {
        metric      = "DatabaseConnections"
        operator    = "GreaterThanThreshold"
        threshold   = floor(var.max_connections * var.connections_percent / 100)
        description = "Connections are above ${var.connections_percent}% of max_connections (${var.max_connections})."
      }
    } : {},
  )
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
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = local.dimension
  statistic           = each.value.operator == "LessThanThreshold" ? "Minimum" : "Maximum"
  period              = local.period
  evaluation_periods  = var.evaluation_minutes
  datapoints_to_alarm = var.evaluation_minutes
  comparison_operator = each.value.operator
  threshold           = each.value.threshold

  # A metric the class or volume does not report must not page anyone.
  treat_missing_data = "notBreaching"

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
