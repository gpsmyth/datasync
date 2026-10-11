#--------------------------------------------------------------------------------
# Datasync locations
#--------------------------------------------------------------------------------
resource "aws_datasync_location_s3" "source" {
  s3_bucket_arn = aws_s3_bucket.source.arn
  subdirectory  = "/"

  s3_config {
    bucket_access_role_arn = aws_iam_role.source.arn
  }

  depends_on = [aws_iam_role_policy.source, ]
}

resource "aws_datasync_location_s3" "dest" {
  s3_bucket_arn    = aws_s3_bucket.dest.arn
  subdirectory     = "/"
  s3_storage_class = "STANDARD" # try STANDARD_IA or GLACIER_IR later

  s3_config {
    bucket_access_role_arn = aws_iam_role.dest.arn
  }

  depends_on = [aws_iam_role_policy.dest, ]
}

# ---------------------------------------------------------------------------
# DataSync Task
# ---------------------------------------------------------------------------
resource "aws_datasync_task" "s3-to-s3" {
  name = "s3-to-s3"

  source_location_arn      = aws_datasync_location_s3.source.arn
  destination_location_arn = aws_datasync_location_s3.dest.arn

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync.arn

  task_mode = "BASIC" # Default is BASIC but could be "ENHANCED" for high performance transfers

  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/datasync_task#options-1
  options {
    verify_mode            = "POINT_IN_TIME_CONSISTENT"
    overwrite_mode         = "ALWAYS" # Default is ALWAYS, but could be NEVER
    transfer_mode          = "CHANGED"
    log_level              = "TRANSFER" # provider default is OFF, which writes no logs
    preserve_deleted_files = "PRESERVE" # Default is PRESERVE, but could be REMOVE
    # "REMOVE" mirrors deletes to the destination

    # POSIX metadata does not apply to S3 locations. The console sets these
    # to NONE; leaving the provider defaults (PRESERVE / INT_VALUE) can cause
    # an API error or a permanent diff on plan.
    posix_permissions = "NONE" # Default is PRESERVE
    uid               = "NONE" # Default is INT_VALUE (numeric user ID)
    gid               = "NONE" # Default is INT_VALUE (numeric group ID)
    preserve_devices  = "NONE" # Default is "NONE" (ignore block and character device files).
  }

  # No implicit dependency exists between the task and the log policy, and
  # CreateTask fails if DataSync can't yet write to the log group.
  depends_on = [aws_cloudwatch_log_resource_policy.datasync]
}