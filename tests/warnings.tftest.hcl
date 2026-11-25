# The default warnings, the empty alarms and the combined alarm. No credentials, no database.

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
}

run "default_warns_at_240_60_and_20_minutes_and_at_empty" {
  command = plan

  assert {
    condition = length(setsubtract([
      for pair in setproduct(
        ["cpu-credit-balance", "ebs-byte-balance", "ebs-io-balance", "storage-burst-balance"],
        ["240m", "60m", "20m", "empty"],
      ) : "${pair[0]}-${pair[1]}"
    ], keys(aws_cloudwatch_metric_alarm.this))) == 0
    error_message = "Each balance has an alarm at 240, 60 and 20 minutes and at empty."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 19
    error_message = "Four balances have four alarms each, plus free memory, swap and the combined alarm."
  }
}

run "long_warnings_use_the_hours_rate" {
  command = plan

  assert {
    condition = {
      for m in ["240m", "60m", "20m"] : m => [
        for q in aws_cloudwatch_metric_alarm.this["ebs-byte-balance-${m}"].metric_query : q.metric[0].period if q.id == "balance"
      ]
    } == { "240m" = [3600], "60m" = [300], "20m" = [300] }
    error_message = "A warning over an hour reads an hour at a time."
  }

  assert {
    condition = {
      for m in ["240m", "60m", "20m"] :
      m => one([for q in aws_cloudwatch_metric_alarm.this["ebs-byte-balance-${m}"].metric_query : q.expression if q.return_data])
      } == {
      "240m" = "balance + RATE(balance) * 14400"
      "60m"  = "balance + RATE(balance) * 3600"
      "20m"  = "balance + RATE(balance) * 1200"
    }
    error_message = "RATE is per second, so the multiplier is the minutes times 60."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-byte-balance-240m"].evaluation_periods == 1
    error_message = "One hour's point is enough."
  }
}

run "empty_alarms_read_the_low_of_the_metric" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["cpu-credit-balance", "ebs-byte-balance", "ebs-io-balance", "storage-burst-balance"] :
      aws_cloudwatch_metric_alarm.this["${k}-empty"].statistic == "Minimum"
      && aws_cloudwatch_metric_alarm.this["${k}-empty"].period == 300
      && aws_cloudwatch_metric_alarm.this["${k}-empty"].comparison_operator == "LessThanOrEqualToThreshold"
    ])
    error_message = "An empty balance is the lowest reading of the period at or below 1% of full."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-byte-balance-empty"].metric_name == "EBSByteBalance%" && output.thresholds["ebs-byte-balance-empty"] == 1 && output.thresholds["cpu-credit-balance-empty"] == 2.88
    error_message = "1% of a percent balance is 1, and 1% of a micro's 288 credits is 2.88."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-byte-balance-empty"].alarm_description == "The instance's EBS throughput burst is spent (1% or less). Swapping drains it."
    error_message = "The description is for the empty state, with no warning in it."
  }
}

run "combined_alarm_reads_two_resources_over_the_hour" {
  command = plan

  assert {
    condition     = one([for q in aws_cloudwatch_metric_alarm.this["ebs-falls-while-swap-grows"].metric_query : q.expression if q.return_data]) == "IF(RATE(ebs) * 3600 < -10 AND RATE(swap) * 3600 > 25000000, 1, 0)"
    error_message = "EBS must fall by more than 10 points and swap grow by more than 25 MB in the same hour."
  }

  assert {
    condition = {
      for q in aws_cloudwatch_metric_alarm.this["ebs-falls-while-swap-grows"].metric_query :
      q.id => "${q.metric[0].metric_name} ${q.metric[0].stat} ${q.metric[0].period}" if q.expression == null
    } == { ebs = "EBSByteBalance% Minimum 3600", swap = "SwapUsage Maximum 3600" }
    error_message = "EBS is the hour's low and swap is the hour's high."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["ebs-falls-while-swap-grows"].comparison_operator == "GreaterThanOrEqualToThreshold" && aws_cloudwatch_metric_alarm.this["ebs-falls-while-swap-grows"].threshold == 1
    error_message = "The expression's 1 breaches and its 0 does not."
  }
}

run "an_empty_list_leaves_only_the_empty_alarms" {
  command = plan

  variables {
    minutes_of_warning = []
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 7 && contains(keys(aws_cloudwatch_metric_alarm.this), "ebs-byte-balance-empty")
    error_message = "No projections, and the four empty alarms, free memory, swap and the combined alarm stay."
  }
}

run "warnings_reject_a_repeated_number" {
  command = plan

  variables {
    minutes_of_warning = [20, 20]
  }

  expect_failures = [var.minutes_of_warning]
}

run "warnings_reject_one_bad_number_in_the_list" {
  command = plan

  variables {
    minutes_of_warning = [240, 0]
  }

  expect_failures = [var.minutes_of_warning]
}

run "warnings_reject_more_than_a_day_in_the_list" {
  command = plan

  variables {
    minutes_of_warning = [20, 1441]
  }

  expect_failures = [var.minutes_of_warning]
}

run "non_burstable_class_has_no_credit_alarms" {
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
    condition     = length([for k in keys(aws_cloudwatch_metric_alarm.this) : k if startswith(k, "cpu-credit-balance")]) == 0
    error_message = "An m7g earns no CPU credits, in any of the four kinds of alarm."
  }
}

run "alarms_notify_by_default" {
  command = plan

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : a.actions_enabled])
    error_message = "Alarms notify unless told otherwise."
  }
}

run "actions_enabled_false_silences_every_alarm" {
  command = plan

  variables {
    actions_enabled = false
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.this : !a.actions_enabled])
    error_message = "A silent rollout silences every alarm."
  }
}
