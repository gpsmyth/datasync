# ---------------------------------------------------------------------------
# Local Values
# ---------------------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id

  source_bucket_name    = "datasync-learning-source-${local.account_id}"
  dest_bucket_name      = "datasync-learning-dest-${local.account_id}"
  reporting_bucket_name = "datasync-learning-reporting-${local.account_id}"

  bucket_ids = {
    source    = aws_s3_bucket.source.id
    dest      = aws_s3_bucket.dest.id
    reporting = aws_s3_bucket.reporting.id
  }

  bucket_arns = {
    source    = aws_s3_bucket.source.arn
    dest      = aws_s3_bucket.dest.arn
    reporting = aws_s3_bucket.reporting.arn
  }

  bucket_names = {
    source    = aws_s3_bucket.source.bucket
    dest      = aws_s3_bucket.dest.bucket
    reporting = aws_s3_bucket.reporting.bucket
  }

  common_tags = {
    Project     = "datasync-learning"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}