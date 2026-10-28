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
  description = "Alarm when free memory stays below this percent of the instance's memory. 10 is about 100 MB on a 1 GiB class."
  type        = number
  default     = 10
}

variable "swap_usage_bytes" {
  description = "Alarm when swap use goes above this many bytes."
  type        = number
  default     = 268435456
}

variable "cpu_credit_percent" {
  description = "Burstable classes only: alarm when the CPU credit balance falls below this percent of the most the class can bank."
  type        = number
  default     = 20
}

variable "burst_balance_percent" {
  description = "Alarm when the EBS byte, EBS I/O or gp2 storage burst balance falls below this percent."
  type        = number
  default     = 20
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
  description = "How long a metric must breach before the alarm fires."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags for every resource the module creates."
  type        = map(string)
  default     = {}
}
