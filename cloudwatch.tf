# ---------------------------------------------------------------------------
# CloudWatch logging
#
# DataSync does NOT use an IAM role to write task logs. It writes as the
# service principal, so access is granted by a resource policy on the log
# group (account-level, per region), not by a role.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "datasync" {
  name              = "/aws/datasync/s3tos3"
  retention_in_days = 3 # keep it cheap
}

# ---------------------------------------------------------------------------
# Resource Policy for CloudWatch logging Resource for DataSync Service
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "datasync_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.datasync.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["datasync.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "datasync" {
  policy_name     = "datasyncs3tos3"
  policy_document = data.aws_iam_policy_document.datasync_logs.json
}