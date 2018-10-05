provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.region}"
}

# cloudtrail trail needs a bucket to log into, bucket needs a policy,
# cloudwatch logging needs a role and policy to pick up cloudtrail trail

resource "aws_cloudtrail" "cloudtrail_log" {
  name                          = "cloudtrail-log-tf"
  s3_bucket_name                = "${aws_s3_bucket.logbucket.id}"
  s3_key_prefix                 = "ctlogs"
  include_global_service_events = false
  cloud_watch_logs_role_arn     = "${aws_iam_role.logging_role.arn}"
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.log_group.arn}"

  depends_on = [
    "aws_s3_bucket_policy.logbucket_policy",
  ]
}

resource "aws_s3_bucket" "logbucket" {
  bucket        = "${var.cloudtrail_s3_bucket_name}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "logbucket_policy" {
  bucket = "${aws_s3_bucket.logbucket.id}"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "${aws_s3_bucket.logbucket.arn}"
        },
        {
            "Sid": "AWSCloudTrailWrite",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "${aws_s3_bucket.logbucket.arn}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_cloudwatch_log_group" "log_group" {
  name = "cloudtrail-log-group-tf"
}

resource "aws_iam_role" "logging_role" {
  name = "cloudwatch-logging-role-tf"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "logging_policy" {
  name = "cloudwatch-logging-policy-tf"
  role = "${aws_iam_role.logging_role.id}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream"
      ],
      "Resource": [
        "${aws_cloudwatch_log_group.log_group.arn}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:PutLogEvents"
      ],
      "Resource": [
        "${aws_cloudwatch_log_group.log_group.arn}"
      ]
    }
  ]
}
POLICY
}

# create an sns topic to receive notifications from our event processing lambda
# we have to invoke a local provisioner to create email subscription as email protocol is 
# not supported in tf due to resource not getting an arn until the subscription is confirmed 
# - this means the topic subscription is not managed in tf and we can't reference its arn

resource "aws_sns_topic" "bucket_alerts" {
  name = "s3-bucket-public-access-alert-tf"

  provisioner "local-exec" {
    command = "aws sns subscribe --topic-arn ${self.arn} --protocol email --notification-endpoint ${var.alert_email_address}"
  }
}

# create an execution role and policy for the lambda to publish to sns

resource "aws_iam_role" "lambda_role" {
  name = "bucket-alert-lambda-execution-role-tf"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "bucket-alert-lambda-execution-policy-tf"
  role = "${aws_iam_role.lambda_role.id}"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "sns:Publish",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:sns:us-east-1:961508331227:s3-bucket-public-access-alert-tf",
                "arn:aws:logs:*:*:*"
            ]
        },
        {
            "Sid": "S3GetBucketACLandPolicy",
            "Effect": "Allow",
            "Action": [
                "s3:GetBucketAcl",
                "s3:GetBucketPolicy"
            ],
            "Resource": "*"
        },
		{
            "Sid": "S3PutBucketACLAccess",
            "Effect": "Allow",
            "Action": [
                "s3:PutBucketAcl",
                "s3:PutBucketPolicy"
            ],
            "Resource": "arn:aws:s3:::*"
        },
        {
            "Sid": "VisualEditor2",
            "Effect": "Allow",
            "Action": "logs:CreateLogGroup",
            "Resource": "arn:aws:logs:*:*:*"
        },
        {
            "Sid": "LambdaBasicExecutionAccess",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        }
    ]
}
POLICY
}

# create lambda function using zip of local source

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda.py"
  output_path = "lambda.zip"
}

resource "aws_lambda_function" "bucket_alert_lambda" {
  description      = "parses cloudtrail logs from cloudwatch events and alerts sns on public s3 buckets"
  filename         = "lambda.zip"
  function_name    = "alert-open-buckets-tf"
  role             = "${aws_iam_role.lambda_role.arn}"
  handler          = "lambda.lambda_handler"
  source_code_hash = "${base64sha256(file("lambda.zip"))}"
  runtime          = "python3.6"

  environment {
    variables = {
      snsTopicArn = "${aws_sns_topic.bucket_alerts.arn}"
    }
  }
}

# create cloudwatch event rule, target and permission to trigger lambda

resource "aws_cloudwatch_event_rule" "lambda_trigger_rule" {
  name = "cloudwatch-lambda-putbucketacl-rule-tf"

  depends_on = [
    "aws_lambda_function.bucket_alert_lambda",
  ]

  event_pattern = <<PATTERN
{
  "source": [
    "aws.s3"
  ],
  "detail-type": [
    "AWS API Call via CloudTrail"
  ],
  "detail": {
    "eventSource": [
      "s3.amazonaws.com"
    ],
    "eventName": [
      "PutBucketAcl",
	  "PutBucketPolicy",
      "CreateBucket"
    ]
  }
}
PATTERN
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  target_id = "cloudwatch-event-lambda-target-tf"
  rule      = "${aws_cloudwatch_event_rule.lambda_trigger_rule.name}"
  arn       = "${aws_lambda_function.bucket_alert_lambda.arn}"
}

resource "aws_lambda_permission" "allow_cloudwatch_event_permission" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.bucket_alert_lambda.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = "${aws_cloudwatch_event_rule.lambda_trigger_rule.arn}"
}
