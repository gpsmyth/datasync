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

# ---------------------------------------------------------------------------
# Also add a bucket policy to each that denies non-TLS requests 
# (aws:SecureTransport = false). 
# Keep the DataSync role least-privileged: read/list access on the 
# source, write access on the destination, and only the KMS permissions
# it needs if you choose SSE-KMS instead of SSE-S3. Versioning helps 
# recover from overwrites or deletes; add a noncurrent-version 
# lifecycle rule if storage costs need limits.
# 1. Define the bucket
# 2. Build the combined policy document
# Deny any non-TLS request. One policy per bucket: a bucket policy can only
# reference its own bucket's ARN, so each document is built from its own ARN.
# Adding a bucket policy to each that denies non-TLS requests 
# (aws:SecureTransport = false). 
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

# 3. Attach the document to the bucket
# resource "aws_s3_bucket_policy" "source" {
#   bucket = aws_s3_bucket.source.id
#   policy = data.aws_iam_policy_document.deny_non_tls.json
# }

# resource "aws_s3_bucket_policy" "dest" {
#   bucket = aws_s3_bucket.dest.id
#   policy = data.aws_iam_policy_document.deny_non_tls.json
# }
resource "aws_s3_bucket_policy" "this" {
  for_each = local.bucket_ids
  bucket   = each.value
  policy   = data.aws_iam_policy_document.deny_non_tls[each.key].json

  # Avoids a race with the public access block (S3 returns a 409 otherwise)
  depends_on = [aws_s3_bucket_public_access_block.this]
}
