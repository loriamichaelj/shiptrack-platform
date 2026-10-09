variable "name_prefix" {
  description = "Prefix of the key aliases: alias/<name_prefix>-data, -secrets, and -logs."
  type        = string
  default     = "shiptrack"
}

variable "deletion_window_in_days" {
  description = "Days a key waits between a deletion request and its removal."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}
