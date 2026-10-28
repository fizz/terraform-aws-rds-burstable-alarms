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

run "micro_gets_memory_swap_burst_and_credit_alarms" {
  command = plan

  assert {
    condition = toset(keys(aws_cloudwatch_metric_alarm.this)) == toset([
      "freeable-memory", "swap-usage", "ebs-byte-balance", "ebs-io-balance",
      "storage-burst-balance", "cpu-credit-balance",
    ])
    error_message = "A t4g.micro gets six alarms, and no connections alarm without max_connections."
  }

  assert {
    condition     = output.thresholds["freeable-memory"] == 107374182
    error_message = "10% of 1 GiB is 107374182 bytes."
  }

  assert {
    condition     = output.thresholds["cpu-credit-balance"] == 57
    error_message = "A micro banks 12 x 24 = 288 credits; 20% is 57."
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
    condition     = output.thresholds["cpu-credit-balance"] == 115
    error_message = "A small banks 24 x 24 = 576 credits; 20% is 115."
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
    condition     = !contains(keys(aws_cloudwatch_metric_alarm.this), "cpu-credit-balance")
    error_message = "An m7g earns no CPU credits."
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

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["freeable-memory"].statistic == "Minimum"
    error_message = "A one-minute dip in free memory must not be averaged away."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["swap-usage"].statistic == "Maximum"
    error_message = "Swap uses the peak."
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
