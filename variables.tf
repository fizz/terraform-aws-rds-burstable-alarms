variable "db_instance_identifier" {
  description = "The RDS instance to watch."
  type        = string
}

variable "alarm_topic_arn" {
  description = "An SNS topic for the alarms and RDS events. Null creates one, subscribed to alarm_emails."
  type        = string
  default     = null
}

variable "alarm_emails" {
  description = "Addresses subscribed to the created topic. Each one gets a confirmation email from AWS and receives nothing until it is confirmed."
  type        = list(string)
  default     = []
}

variable "freeable_memory_percent" {
  description = "Alarm when free memory stays below this percent of the instance's memory. 10 is about 100 MB on a 1 GiB class. The swap alarm uses the same floor."
  type        = number
  default     = 10
}

variable "minutes_of_warning" {
  description = "Alarm when a CPU credit, EBS byte, EBS I/O or gp2 burst balance will be at 1% of full or less in this many minutes at its present rate. The alarm fires only after evaluation_minutes of that, so the real warning is shorter by as much. At most 1440 (one day), because it carries one 5-minute rate that far forward."
  type        = number
  default     = 20

  validation {
    condition     = var.minutes_of_warning > 0 && var.minutes_of_warning <= 1440
    error_message = "minutes_of_warning must be more than 0 and at most 1440 (one day)."
  }
}

variable "max_connections" {
  description = "The instance's max_connections, from SHOW max_connections. Null skips the connections alarm. The formula depends on memory RDS keeps for itself, so read it instead of computing it."
  type        = number
  default     = null
}

variable "connections_percent" {
  description = "Alarm when connections go above this percent of max_connections."
  type        = number
  default     = 70
}

variable "event_categories" {
  description = "RDS event categories sent to the topic. A forced restart arrives as a recovery event, never as a metric."
  type        = list(string)
  default     = ["failure", "recovery", "low storage", "failover"]
}

variable "evaluation_minutes" {
  description = "How many minutes a metric must breach before the alarm fires. A metric that reports every 5 minutes is evaluated per 5-minute period, so the value is rounded up to a whole number of periods, and is never less than one period (5 minutes)."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags for every resource the module creates."
  type        = map(string)
  default     = {}
}
