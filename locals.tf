# ---------------------------------------------------------------------------
# Local Values
# ---------------------------------------------------------------------------

locals {

  source_bucket_name = "datasync-learning-source"
  dest_bucket_name   = "datasync-learning-dest"

  bucket_ids = {
    source = aws_s3_bucket.source.id
    dest   = aws_s3_bucket.dest.id
  }

  bucket_arns = {
    source = aws_s3_bucket.source.arn
    dest   = aws_s3_bucket.dest.arn
  }

  bucket_names = {
    source = aws_s3_bucket.source.bucket
    dest   = aws_s3_bucket.dest.bucket
  }

  common_tags = {
    Project     = "datasync-learning"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}