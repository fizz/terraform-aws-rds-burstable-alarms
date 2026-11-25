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
  description = "Minutes of warning for each CPU credit, EBS byte, EBS I/O and gp2 burst balance, one alarm for each number: the balance will be at 1% of full or less in that many minutes at its present rate. Numbers up to 60 use a 5-minute rate. Longer ones use the hour's rate, so they fire after an hour's point is in. Every balance also has an alarm at empty. Each number is at most 1440 (one day)."
  type        = list(number)
  default     = [240, 60, 20]

  validation {
    condition     = alltrue([for m in var.minutes_of_warning : m > 0 && m <= 1440])
    error_message = "Each number in minutes_of_warning must be more than 0 and at most 1440 (one day)."
  }

  validation {
    condition     = length(var.minutes_of_warning) == length(distinct(var.minutes_of_warning))
    error_message = "minutes_of_warning must not repeat a number."
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

variable "actions_enabled" {
  description = "Whether the alarms notify the topic. A new alarm moves from no data to OK, which would notify once per alarm, so a rollout can create them with false, wait until every alarm has a state, and set true."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for every resource the module creates."
  type        = map(string)
  default     = {}
}
