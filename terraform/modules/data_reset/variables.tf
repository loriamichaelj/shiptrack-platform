variable "pod_bucket_name" {
  description = "The proof-of-delivery bucket whose pod/ objects the reset removes. It is the document's default for podBucket."
  type        = string
}

variable "document_name" {
  description = "Name of the SSM document. The ShipTrack-* prefix is what the stacks' pipeline roles and the legacy hosts' role allow."
  type        = string
  default     = "ShipTrack-ResetData"

  validation {
    condition     = startswith(var.document_name, "ShipTrack-")
    error_message = "The document name must start with ShipTrack-."
  }
}
