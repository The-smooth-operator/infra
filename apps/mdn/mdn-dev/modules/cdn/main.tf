data "aws_caller_identity" "current" {}

locals {
  site-bucket      = "${var.bucket-name}-${data.aws_caller_identity.current.account_id}"
  site-bucket-logs = "${var.bucket-name}-${data.aws_caller_identity.current.account_id}-logs"
}

resource "aws_s3_bucket" "site-bucket-logs" {
  bucket = "${local.site-bucket-logs}"
  region = "${var.region}"
  acl    = "log-delivery-write"

  tags = {
    Name      = "${local.site-bucket-logs}"
    Service   = "${var.servicename}"
    Terraform = "true"
  }
}

resource "aws_s3_bucket" "site-bucket" {
  bucket = "${local.site-bucket}"
  acl    = "public-read"
  region = "${var.region}"

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }

  logging {
    target_bucket = "${aws_s3_bucket.site-bucket-logs.id}"
    target_prefix = "logs/"
  }

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  versioning {
    enabled = "${var.s3_versioning}"
  }

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Id": "${var.servicename} policy",
  "Statement": [
    {
     	"Sid": "AllowListBucket",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${local.site-bucket}"
    },
    {
      "Sid": "AllowIndexDotHTML",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${local.site-bucket}/*"
    }
  ]
}
EOF

  tags {
    Name      = "${local.site-bucket}"
    Service   = "${var.servicename}"
    Terraform = "true"
  }
}

resource "aws_cloudfront_distribution" "site-distribution" {
  enabled             = "${var.cloudfront_enable}"
  comment             = "Cloudfront distribution for ${var.servicename}"
  default_root_object = "index.html"
  aliases             = "${var.cloudfront_aliases}"
  is_ipv6_enabled     = "${var.enable_ipv6}"

  origin {
    domain_name = "${aws_s3_bucket.site-bucket.website_endpoint}"
    origin_id   = "origin-${local.site-bucket}"

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port              = 80
      https_port             = 443
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.1", "TLSv1"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "origin-${local.site-bucket}"

    lambda_function_association {
      event_type = "viewer-response"
      lambda_arn = "${aws_lambda_function.lambda-headers.qualified_arn}"
    }

    forwarded_values {
      query_string = true

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "${var.cloudfront_protocol_policy}"
    min_ttl                = 0
    default_ttl            = 600
    max_ttl                = 600
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = "${var.acm_certificate_arn}"
    ssl_support_method  = "sni-only"
  }
}

# Lambda@edge to set origin response headers
resource "aws_iam_role" "lambda-edge-role" {
  name = "${var.servicename}-lambda-exec-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
       ]
     },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

data "archive_file" "lambda-zip" {
  type        = "zip"
  source_file = "${path.module}/lambda-headers.js"
  output_path = "${path.module}/lambda-headers.zip"
}

# We do this because lambda@edge needs to be in us-east-1
provider "aws" {
  alias  = "aws-lambda-east"
  region = "us-east-1"
}

resource "aws_lambda_function" "lambda-headers" {
  provider         = "aws.aws-lambda-east"
  function_name    = "${var.servicename}-headers"
  description      = "Provides Correct Response Headers for ${var.servicename}"
  publish          = "true"
  filename         = "${path.module}/lambda-headers.zip"
  source_code_hash = "${data.archive_file.lambda-zip.output_base64sha256}"
  role             = "${aws_iam_role.lambda-edge-role.arn}"
  handler          = "${var.event_trigger}"
  runtime          = "nodejs8.10"

  tags {
    Name        = "${var.servicename}-headers"
    ServiceName = "${var.servicename}"
    Terraform   = "true"
  }
}
