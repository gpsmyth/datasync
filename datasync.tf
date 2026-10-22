#--------------------------------------------------------------------------------
# Datasync locations
#--------------------------------------------------------------------------------
resource "aws_datasync_location_s3" "source" {
  s3_bucket_arn = aws_s3_bucket.source.arn
  subdirectory  = "/"

  s3_config {
    bucket_access_role_arn = aws_iam_role.source.arn
  }

  depends_on = [time_sleep.iam_propagation]
}

resource "aws_datasync_location_s3" "dest" {
  s3_bucket_arn    = aws_s3_bucket.dest.arn
  subdirectory     = "/"
  s3_storage_class = "STANDARD" # try STANDARD_IA or GLACIER_IR later

  s3_config {
    bucket_access_role_arn = aws_iam_role.dest.arn
  }

  depends_on = [time_sleep.iam_propagation]
}

# ---------------------------------------------------------------------------
# DataSync Task
# ---------------------------------------------------------------------------
resource "aws_datasync_task" "s3_to_s3" {
  name = "s3-to-s3"

  source_location_arn      = aws_datasync_location_s3.source.arn
  destination_location_arn = aws_datasync_location_s3.dest.arn

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync.arn
  task_mode                = "BASIC" # Default is BASIC but could be "ENHANCED" for high performance transfers

  # Skip temp files (see sample-data/*.tmp)
  excludes {
    filter_type = "SIMPLE_PATTERN"
    value       = "*.tmp"
  }

  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/datasync_task#options-1
  options {
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS" # Default is ALWAYS, but could be NEVER
    transfer_mode          = "CHANGED"
    log_level              = "TRANSFER" # provider default is OFF, which writes no logs
    preserve_deleted_files = "REMOVE" # Default is PRESERVE, but could be REMOVE
    # "REMOVE" mirrors deletes to the destination

    # POSIX metadata does not apply to S3 locations. The console sets these
    # to NONE; leaving the provider defaults (PRESERVE / INT_VALUE) can cause
    # an API error or a permanent diff on plan.
    posix_permissions = "NONE" # Default is PRESERVE
    uid               = "NONE" # Default is INT_VALUE (numeric user ID)
    gid               = "NONE" # Default is INT_VALUE (numeric group ID)
    preserve_devices  = "NONE" # Default is "NONE" (ignore block and character device files).
  }

  task_report_config {
    output_type          = "STANDARD"
    report_level         = "SUCCESSES_AND_ERRORS"
    s3_object_versioning = "INCLUDE"

    s3_destination {
      s3_bucket_arn          = aws_s3_bucket.reporting.arn
      bucket_access_role_arn = aws_iam_role.reporting.arn
      subdirectory           = "reports/"
    }
  }

  #  terraform plan wants to update the report_overrides on every run, even though the values are identical.
  #  This is a known issue with the provider. 
  # shows as "- report_overrides {}" in the plan
  lifecycle {
    ignore_changes = [task_report_config[0].report_overrides]
  }
  # No implicit dependency exists between the task and the log policy, and
  # CreateTask fails if DataSync can't yet write to the log group.
  depends_on = [
    aws_cloudwatch_log_resource_policy.datasync,
    aws_iam_role_policy.reporting
  ]
}