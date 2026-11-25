# Plan-level checks with a mocked provider: no credentials, no database.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_data "aws_db_instance" {
    defaults = {
      db_instance_class = "db.t4g.micro"
      storage_type      = "gp2"
    }
  }

  mock_data "aws_ec2_instance_type" {
    defaults = {
      memory_size = 1024
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:111122223333:app-db-rds-alarms"
    }
  }
}

variables {
  db_instance_identifier = "app-db"
  alarm_emails           = ["ops@example.com"]
  minutes_of_warning     = [20]
}

run "micro_gets_memory_swap_burst_and_credit_alarms" {
  command = plan

  assert {
    condition = toset(keys(aws_cloudwatch_metric_alarm.this)) == toset([
      "freeable-memory", "swap-usage", "ebs-falls-while-swap-grows",
      "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m", "cpu-credit-balance-20m",
      "ebs-byte-balance-empty", "ebs-io-balance-empty", "storage-burst-balance-empty", "cpu-credit-balance-empty",
    ])
    error_message = "With one warning a t4g.micro gets eleven alarms, and no connections alarm without max_connections."
  }

  assert {
    condition     = output.thresholds["freeable-memory"] == 107374182
    error_message = "10% of 1 GiB is 107374182 bytes."
  }

  assert {
    condition     = output.thresholds["cpu-credit-balance-20m"] == 2.88
    error_message = "A micro banks 12 x 24 = 288 credits; 1% is 2.88."
  }

  assert {
    condition = alltrue([
      for k in ["ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m", "swap-usage"] : output.thresholds[k] == 1
    ])
    error_message = "1% of a percent balance is 1, and the swap expression is 1 or 0."
  }
}

run "memory_threshold_follows_the_class" {
  command = plan

  override_data {
    target = data.aws_db_instance.this
    values = { db_instance_class = "db.t4g.small" }
  }

  override_data {
    target = data.aws_ec2_instance_type.this
    values = { memory_size = 2048 }
  }

  assert {
    condition     = output.thresholds["freeable-memory"] == 214748364
    error_message = "Moving to a small doubles the memory threshold without any input changing."
  }

  assert {
    condition     = output.thresholds["cpu-credit-balance-20m"] == 5.76
    error_message = "A small banks 24 x 24 = 576 credits; 1% is 5.76."
  }
}

run "non_burstable_class_has_no_credit_alarm" {
  command = plan

  override_data {
    target = data.aws_db_instance.this
    values = { db_instance_class = "db.m7g.large" }
  }

  override_data {
    target = data.aws_ec2_instance_type.this
    values = { memory_size = 8192 }
  }

  assert {
    condition     = !contains(keys(aws_cloudwatch_metric_alarm.this), "cpu-credit-balance-20m")
    error_message = "An m7g earns no CPU credits."
  }

  assert {
    condition = alltrue([
      for k in ["ebs-byte-balance-20m", "ebs-io-balance-20m", "swap-usage"] :
      contains(keys(aws_cloudwatch_metric_alarm.this), k)
    ])
    error_message = "The EBS balance and swap alarms do not depend on CPU credits."
  }
}

run "connections_alarm_needs_the_measured_max" {
  command = plan

  variables {
    max_connections = 79
  }

  assert {
    condition     = output.thresholds["connections"] == 55
    error_message = "70% of 79 is 55."
  }
}

run "lows_use_minimum_and_highs_use_maximum" {
  command = plan

  variables {
    max_connections = 79
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["freeable-memory"].statistic == "Minimum"
    error_message = "A one-minute dip in free memory must not be averaged away."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["connections"].statistic == "Maximum"
    error_message = "Connections use the peak."
  }

  assert {
    condition = alltrue(flatten([
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m"] : [
        for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.metric[0].stat == "Minimum" if q.id == "balance"
      ]
    ]))
    error_message = "A balance uses its low."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.treat_missing_data == "notBreaching"])
    error_message = "A metric the class does not report must not fire."
  }
}

run "created_topic_gets_emails_and_rds_events" {
  command = plan

  assert {
    condition     = length(aws_sns_topic.alarms) == 1 && length(aws_sns_topic_subscription.email) == 1
    error_message = "With no topic given, the module creates one and subscribes each email."
  }

  assert {
    condition     = contains(aws_db_event_subscription.this.event_categories, "recovery")
    error_message = "A forced restart is a recovery event; it has no metric."
  }
}

run "given_topic_creates_no_topic" {
  command = plan

  variables {
    alarm_topic_arn = "arn:aws:sns:us-east-1:111122223333:existing"
    alarm_emails    = []
  }

  assert {
    condition     = length(aws_sns_topic.alarms) == 0 && length(aws_sns_topic_subscription.email) == 0
    error_message = "A given topic is used as is."
  }

  assert {
    condition     = output.alarm_topic_arn == "arn:aws:sns:us-east-1:111122223333:existing"
    error_message = "Alarms publish to the given topic."
  }
}

run "math_alarms_use_a_five_minute_period" {
  command = plan

  variables {
    max_connections = 79
  }

  assert {
    condition = alltrue(flatten([
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m", "swap-usage"] : [
        for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.metric[0].period == 300 if q.expression == null
      ]
    ]))
    error_message = "The balance and swap alarms read every metric on a 5-minute period."
  }

  assert {
    condition = alltrue([
      for k in ["freeable-memory", "connections"] :
      aws_cloudwatch_metric_alarm.this[k].period == 60
    ])
    error_message = "The other metrics keep a 60-second period."
  }

  assert {
    condition = alltrue([
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m", "swap-usage"] :
      aws_cloudwatch_metric_alarm.this[k].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.this[k].datapoints_to_alarm == 1
    ])
    error_message = "The default 5 minutes is one 5-minute period."
  }

  assert {
    condition = alltrue([
      for k in ["freeable-memory", "connections"] :
      aws_cloudwatch_metric_alarm.this[k].evaluation_periods == 5 && aws_cloudwatch_metric_alarm.this[k].datapoints_to_alarm == 5
    ])
    error_message = "The default 5 minutes is five 1-minute periods."
  }
}

run "evaluation_minutes_rounds_up_to_whole_periods" {
  command = plan

  variables {
    evaluation_minutes = 7
    max_connections    = 79
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["cpu-credit-balance-20m"].evaluation_periods == 2 && aws_cloudwatch_metric_alarm.this["cpu-credit-balance-20m"].datapoints_to_alarm == 2
    error_message = "7 minutes on a 5-minute metric is two periods."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["freeable-memory"].evaluation_periods == 7 && aws_cloudwatch_metric_alarm.this["connections"].datapoints_to_alarm == 7
    error_message = "7 minutes on a 1-minute metric is seven periods."
  }
}

run "evaluation_minutes_below_one_period_is_one_period" {
  command = plan

  variables {
    evaluation_minutes = 1
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-io-balance-20m"].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.this["ebs-io-balance-20m"].datapoints_to_alarm == 1
    error_message = "A 5-minute metric cannot be evaluated over less than one period."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["freeable-memory"].evaluation_periods == 1
    error_message = "1 minute on a 1-minute metric is one period."
  }
}

run "balance_alarms_project_the_balance" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m"] :
      one([for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.expression if q.return_data]) == "balance + RATE(balance) * 1200"
    ])
    error_message = "RATE is per second, so 20 minutes is 1200 of them, in percent and in credits alike."
  }

  assert {
    condition = {
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m"] :
      k => one([for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.metric[0].metric_name if q.id == "balance"])
      } == {
      cpu-credit-balance-20m    = "CPUCreditBalance"
      ebs-byte-balance-20m      = "EBSByteBalance%"
      ebs-io-balance-20m        = "EBSIOBalance%"
      storage-burst-balance-20m = "BurstBalance"
    }
    error_message = "Each balance alarm reads its own metric."
  }
}

run "math_alarms_compare_one_returned_expression" {
  command = plan

  assert {
    condition = {
      for k, a in aws_cloudwatch_metric_alarm.this :
      k => [for q in a.metric_query : q.id if q.return_data]
      } == {
      freeable-memory             = []
      swap-usage                  = ["swapping"]
      ebs-falls-while-swap-grows  = ["together"]
      cpu-credit-balance-20m      = ["projected"]
      ebs-byte-balance-20m        = ["projected"]
      ebs-io-balance-20m          = ["projected"]
      storage-burst-balance-20m   = ["projected"]
      cpu-credit-balance-empty    = []
      ebs-byte-balance-empty      = []
      ebs-io-balance-empty        = []
      storage-burst-balance-empty = []
    }
    error_message = "A math alarm returns its one expression, and nothing else."
  }

  assert {
    condition = alltrue([
      for k, a in aws_cloudwatch_metric_alarm.this :
      a.metric_name == null && a.namespace == null && a.statistic == null && a.period == null && a.dimensions == null
      if k != "freeable-memory" && !endswith(k, "-empty")
    ])
    error_message = "A math alarm has no metric of its own."
  }

  assert {
    condition = alltrue(flatten([
      for k, a in aws_cloudwatch_metric_alarm.this : [
        for q in a.metric_query :
        q.metric[0].namespace == "AWS/RDS" && q.metric[0].dimensions == tomap({ DBInstanceIdentifier = "app-db" })
        if q.expression == null
      ]
    ]))
    error_message = "Every input metric is this instance's."
  }
}

# Fails if a spent balance is dropped. At a rate of 0, or with no rate, the projection is the
# balance itself, so it is the threshold and the operator that make a spent balance alarm.
run "spent_balance_alarms_when_its_rate_is_zero" {
  command = plan

  assert {
    condition = {
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m"] :
      k => "${aws_cloudwatch_metric_alarm.this[k].comparison_operator} ${aws_cloudwatch_metric_alarm.this[k].threshold}"
      } == {
      cpu-credit-balance-20m    = "LessThanOrEqualToThreshold 2.88"
      ebs-byte-balance-20m      = "LessThanOrEqualToThreshold 1"
      ebs-io-balance-20m        = "LessThanOrEqualToThreshold 1"
      storage-burst-balance-20m = "LessThanOrEqualToThreshold 1"
    }
    error_message = "A balance at or below 1% of full breaches."
  }

  assert {
    condition = alltrue([
      for k in ["cpu-credit-balance-20m", "ebs-byte-balance-20m", "ebs-io-balance-20m", "storage-burst-balance-20m"] :
      startswith(one([for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.expression if q.return_data]), "balance + RATE(balance)")
    ])
    error_message = "The balance is a term of its own, with no condition on its rate."
  }
}

run "longest_warning_does_not_move_the_threshold" {
  command = plan

  variables {
    minutes_of_warning = [1440]
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["ebs-byte-balance-1440m"].metric_query : q.expression if q.return_data]) == "balance + RATE(balance) * 86400"
    error_message = "1440 minutes is 86400 seconds."
  }

  assert {
    condition     = output.thresholds["ebs-byte-balance-1440m"] == 1
    error_message = "A flat balance above 1% is quiet at any warning."
  }
}

# Fails if FILL or a division comes back, in any alarm. FILL gives a metric that is never
# reported a full series of points. An operation between two series counts the missing one as
# 0, so balance / filled is 0 for a balance that does not exist, and 0 pages.
run "expressions_have_no_fill_and_no_division" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for a in aws_cloudwatch_metric_alarm.this : [
        for q in a.metric_query : length(regexall("(?i)fill|/", q.expression)) == 0 if q.expression != null
      ]
    ]))
    error_message = "No expression may fill a series or divide by one."
  }

  assert {
    condition     = sum([for a in aws_cloudwatch_metric_alarm.this : length([for q in a.metric_query : q if q.expression != null])]) == 6
    error_message = "Four balances, swap and the combined alarm have one expression each, so the check above read six."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.treat_missing_data == "notBreaching"])
    error_message = "An expression with no point must not fire."
  }
}

run "large_burstable_class_scales_credits_and_memory" {
  command = plan

  override_data {
    target = data.aws_db_instance.this
    values = { db_instance_class = "db.t4g.2xlarge", storage_type = "gp3" }
  }

  override_data {
    target = data.aws_ec2_instance_type.this
    values = { memory_size = 32768 }
  }

  assert {
    condition     = output.thresholds["cpu-credit-balance-20m"] == 46.08
    error_message = "A 2xlarge banks 192 x 24 = 4608 credits; 1% is 46.08."
  }

  assert {
    condition     = output.thresholds["ebs-byte-balance-20m"] == 1
    error_message = "A percent balance does not depend on the class."
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["cpu-credit-balance-20m"].metric_query : q.expression if q.return_data]) == "balance + RATE(balance) * 1200"
    error_message = "The class moves the threshold, not the expression."
  }

  assert {
    condition     = output.thresholds["freeable-memory"] == 3435973836
    error_message = "10% of 32 GiB is 3435973836 bytes."
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["swap-usage"].metric_query : q.expression if q.return_data]) == "IF(free < 3435973836 AND RATE(swap) > 0, 1, 0)"
    error_message = "The swap alarm uses the class's memory floor, as a plain integer."
  }
}

run "gp2_volume_gets_a_storage_burst_alarm" {
  command = plan

  assert {
    condition     = contains(keys(aws_cloudwatch_metric_alarm.this), "storage-burst-balance-20m")
    error_message = "A gp2 volume has a burst balance."
  }
}

run "gp3_volume_gets_no_storage_burst_alarm" {
  command = plan

  override_data {
    target = data.aws_db_instance.this
    values = { db_instance_class = "db.t4g.micro", storage_type = "gp3" }
  }

  assert {
    condition = toset(keys(aws_cloudwatch_metric_alarm.this)) == toset([
      "freeable-memory", "swap-usage", "ebs-falls-while-swap-grows",
      "ebs-byte-balance-20m", "ebs-io-balance-20m", "cpu-credit-balance-20m",
      "ebs-byte-balance-empty", "ebs-io-balance-empty", "cpu-credit-balance-empty",
    ])
    error_message = "A gp3 volume has no burst balance, and keeps every other alarm."
  }

  assert {
    condition     = !contains(keys(output.thresholds), "storage-burst-balance-20m") && !contains(keys(output.alarm_names), "storage-burst-balance-20m")
    error_message = "The outputs list only alarms that exist."
  }
}

run "swap_alarm_needs_low_memory_and_growing_swap" {
  command = plan

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["swap-usage"].metric_query : q.expression if q.return_data]) == "IF(free < 107374182 AND RATE(swap) > 0, 1, 0)"
    error_message = "Swap that holds steady, or grows with memory free, is quiet."
  }

  assert {
    condition = {
      for q in aws_cloudwatch_metric_alarm.this["swap-usage"].metric_query :
      q.id => "${q.metric[0].metric_name} ${q.metric[0].stat}" if q.expression == null
    } == { free = "FreeableMemory Maximum", swap = "SwapUsage Maximum" }
    error_message = "Memory must be under the floor for the whole period."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["swap-usage"].comparison_operator == "GreaterThanOrEqualToThreshold" && aws_cloudwatch_metric_alarm.this["swap-usage"].threshold == 1
    error_message = "The expression's 1 breaches and its 0 does not."
  }
}

run "swap_alarm_follows_freeable_memory_percent" {
  command = plan

  variables {
    freeable_memory_percent = 25
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["swap-usage"].metric_query : q.expression if q.return_data]) == "IF(free < 268435456 AND RATE(swap) > 0, 1, 0)" && output.thresholds["freeable-memory"] == 268435456
    error_message = "The memory and swap alarms share one floor: 25% of 1 GiB is 268435456 bytes."
  }
}

run "minutes_of_warning_sets_every_balance_alarm" {
  command = plan

  variables {
    minutes_of_warning = [45]
  }

  assert {
    condition = alltrue([
      for k in ["cpu-credit-balance-45m", "ebs-byte-balance-45m", "ebs-io-balance-45m", "storage-burst-balance-45m"] :
      one([for q in aws_cloudwatch_metric_alarm.this[k].metric_query : q.expression if q.return_data]) == "balance + RATE(balance) * 2700"
    ])
    error_message = "One input sets the four balance alarms."
  }

  assert {
    condition = output.thresholds == {
      freeable-memory             = 107374182
      swap-usage                  = 1
      ebs-falls-while-swap-grows  = 1
      cpu-credit-balance-45m      = 2.88
      ebs-byte-balance-45m        = 1
      ebs-io-balance-45m          = 1
      storage-burst-balance-45m   = 1
      cpu-credit-balance-empty    = 2.88
      ebs-byte-balance-empty      = 1
      ebs-io-balance-empty        = 1
      storage-burst-balance-empty = 1
    }
    error_message = "It moves no threshold."
  }
}

run "balance_descriptions_say_the_warning_and_the_unit" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["cpu-credit-balance-20m"].alarm_description == "The CPU credit balance will be spent (2.88 credits or less) within 20 minutes at its present rate, or is spent now. A db.t4g.micro can bank 288."
    error_message = "Credits are a count."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-io-balance-20m"].alarm_description == "The instance's EBS I/O burst will be spent (1% or less) within 20 minutes at its present rate, or is spent now."
    error_message = "EBS balances are percents."
  }
}

run "minutes_of_warning_takes_less_than_a_minute" {
  command = plan

  variables {
    minutes_of_warning = [0.5]
  }

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["ebs-byte-balance-0.5m"].metric_query : q.expression if q.return_data]) == "balance + RATE(balance) * 30"
    error_message = "Any positive number is accepted, and half a minute is 30 seconds."
  }
}

run "minutes_of_warning_rejects_zero" {
  command = plan

  variables {
    minutes_of_warning = [0]
  }

  expect_failures = [var.minutes_of_warning]
}

run "minutes_of_warning_rejects_a_negative" {
  command = plan

  variables {
    minutes_of_warning = [-20]
  }

  expect_failures = [var.minutes_of_warning]
}

run "minutes_of_warning_rejects_more_than_a_day" {
  command = plan

  variables {
    minutes_of_warning = [1441]
  }

  expect_failures = [var.minutes_of_warning]
}
