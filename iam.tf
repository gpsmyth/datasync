#---------------------------------------------------------------------------
# IAM Roles and Policies for DataSync
#---------------------------------------------------------------------------

# Trust policy for DataSync because DataSync assumes the role
data "aws_iam_policy_document" "datasync_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["datasync.amazonaws.com"]
    }

    # Confused-deputy protection: restricts to your AWS account. 
    # See https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Source: read-only
# assume_role_policy implies:
# 1. Trust policy (Who)
# 2. Who can assume the role
resource "aws_iam_role" "source" {
  name               = "datasync-s3-source"
  assume_role_policy = data.aws_iam_policy_document.datasync_assume.json
}

# Permissions policy:
# Once DataSync has assumed the role,
# what is the role allowed to do?
data "aws_iam_policy_document" "source_access" {
  statement {
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.source.arn]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetObjectVersionTagging",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }
}

# Whenever aws_iam_role_policy is created
# 1. PERMISSIONS POLICY (What)
# 2. What can this role do?
resource "aws_iam_role_policy" "source" {
  name   = "s3-read"
  role   = aws_iam_role.source.id
  policy = data.aws_iam_policy_document.source_access.json
}

# Destination: read/write/delete
resource "aws_iam_role" "dest" {
  name               = "datasync-s3-dest"
  assume_role_policy = data.aws_iam_policy_document.datasync_assume.json
}

data "aws_iam_policy_document" "dest_access" {
  statement {
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.dest.arn]
  }

  statement {
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetObjectVersionTagging",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = ["${aws_s3_bucket.dest.arn}/*"]
  }
}

resource "aws_iam_role_policy" "dest" {
  name   = "s3-read-write"
  role   = aws_iam_role.dest.id
  policy = data.aws_iam_policy_document.dest_access.json
}

resource "aws_iam_role" "reporting" {
  name               = "datasync-s3-reporting"
  assume_role_policy = data.aws_iam_policy_document.datasync_assume.json
}

data "aws_iam_policy_document" "reporting_access" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reporting.arn}/reports/*"]
  }
}

resource "aws_iam_role_policy" "reporting" {
  name   = "s3-reports-write"
  role   = aws_iam_role.reporting.id
  policy = data.aws_iam_policy_document.reporting_access.json
}

# Wait 30 seconds for IAM propagation before creating the DataSync task.
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"

  # Adding a trigger for recreated role or an edited trust policy
  # rather than a role permission edit
  triggers = {
    source_role = aws_iam_role.source.unique_id
    source_trust = sha256(aws_iam_role.source.assume_role_policy)
    dest_role   = aws_iam_role.dest.unique_id
    dest_trust  = sha256(aws_iam_role.dest.assume_role_policy)
  }
  
  depends_on = [
    aws_iam_role_policy.source,
    aws_iam_role_policy.dest,
  ]
}
