# Instance role for the database nodes so backup-mysql.sh can write to S3
# WITHOUT any long-lived access key on the host. This is the whole reason
# instance profiles exist, and it is what IMDSv2 protects.

resource "aws_iam_role" "db" {
  name = "${var.project}-db-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project}-db-role" }
}

resource "aws_iam_role_policy" "db_backups" {
  name = "${var.project}-db-backups"
  role = aws_iam_role.db.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteAndReadBackups"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
      {
        Sid    = "UseBackupKey"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.backups.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "db" {
  name = "${var.project}-db-profile"
  role = aws_iam_role.db.name
}
