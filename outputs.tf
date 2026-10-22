# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "source_bucket" {
  value = aws_s3_bucket.source.id
}

output "dest_bucket" {
  value = aws_s3_bucket.dest.id
}

output "reporting_bucket" {
  value = aws_s3_bucket.reporting.id
}

output "bucket_names" {
  value = local.bucket_names
}

output "task_arn" {
  value = aws_datasync_task.s3_to_s3.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.datasync.name
}

output "start_task_command" {
  value = "aws datasync start-task-execution --region ${var.aws_region} --task-arn ${aws_datasync_task.s3_to_s3.arn}"
}
