# ---------------------------------------------------------------------------
# Buckets
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "source" {
  bucket        = local.source_bucket_name
  force_destroy = true # lets `terraform destroy` clean up non-empty buckets
}

resource "aws_s3_bucket" "dest" {
  bucket        = local.dest_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket" "reporting" {
  bucket        = local.reporting_bucket_name
  force_destroy = true
}

# ---------------------------------------------------------------------------
# Hardening
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.bucket_ids
  bucket   = each.value

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.bucket_ids
  bucket   = each.value

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.bucket_ids
  bucket   = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.bucket_ids
  bucket   = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning keeps old copies on every overwrite/delete; expire them so
# storage costs stay bounded.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.bucket_ids
  bucket   = each.value

  rule {
    id     = "expire-noncurrent-and-abort-mpu"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = each.key == "reporting" ? [1] : []

    content {
      id     = "expire-reports-after-30-days"
      status = "Enabled"

      filter {
        prefix = "reports/"
      }

      expiration {
        days = 30
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Deny any non-TLS request. One policy per bucket: a bucket policy can only
# reference its own bucket's ARN, so each document is built from its own ARN.
data "aws_iam_policy_document" "deny_non_tls" {
  for_each = local.bucket_arns

  statement {
    sid    = "EnforceTLSRequestsOnly"
    effect = "Deny"

    actions = ["s3:*"]

    resources = [
      each.value,
      "${each.value}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.bucket_ids
  bucket   = each.value
  policy   = data.aws_iam_policy_document.deny_non_tls[each.key].json

  # Avoids a race with the public access block (S3 returns a 409 otherwise)
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Added Data: everything under ./sample-data is uploaded to the source bucket.
# Add, edit or delete files locally, `terraform apply`, then re-run the task.
# ---------------------------------------------------------------------------
resource "aws_s3_object" "sample_data" {
  for_each = fileset("${path.module}/sample-data", "**")

  bucket = aws_s3_bucket.source.id
  key    = each.value

  source      = "${path.module}/sample-data/${each.value}"
  source_hash = filemd5("${path.module}/sample-data/${each.value}")

  depends_on = [aws_s3_bucket_versioning.this, aws_s3_bucket_policy.this]
}
