output "alarm_topic_arn" {
  description = "The topic the alarms and RDS events publish to."
  value       = local.topic_arn
}

output "alarm_names" {
  description = "Every alarm the module created, by key."
  value       = { for k, a in aws_cloudwatch_metric_alarm.this : k => a.alarm_name }
}

output "thresholds" {
  description = "Each alarm's threshold, after the class's memory and CPU credits are applied."
  value       = { for k, a in local.alarms : k => a.threshold }
}
