terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws",
    }
  }
}

data "aws_caller_identity" "current" {}

## CloudWatch metric stream
resource "aws_cloudwatch_metric_stream" "datadog" {
  name          = "datadog"
  firehose_arn  = aws_kinesis_firehose_delivery_stream.datadog.arn
  output_format = "opentelemetry0.7"
  role_arn      = aws_iam_role.datadog_metric_stream.arn

  dynamic "include_filter" {
    for_each = var.datadog_metric_stream_filters
    iterator = item

    content {
      namespace    = item.value.namespace
      metric_names = item.value.metric_names
    }
  }

  dynamic "statistics_configuration" {
    for_each = var.datadog_metric_statistics_configurations
    iterator = item

    content {
      additional_statistics = item.value.additional_statistics
      dynamic "include_metric" {
        for_each = item.value.include_metric
        iterator = inner_item

        content {
          metric_name = inner_item.value.metric_name
          namespace   = inner_item.value.namespace
        }
      }
    }
  }
}

resource "aws_iam_role" "datadog_metric_stream" {
  # note: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-metric-streams-trustpolicy.html
  name                = "datadog-metric-stream"
  assume_role_policy  = data.aws_iam_policy_document.datadog_metric_stream_assume_role.json
  managed_policy_arns = []

  inline_policy {
    name   = "firehose"
    policy = data.aws_iam_policy_document.datadog_metric_stream_firehose.json
  }
}

data "aws_iam_policy_document" "datadog_metric_stream_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["streams.metrics.cloudwatch.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "datadog_metric_stream_firehose" {
  statement {
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]

    resources = [aws_kinesis_firehose_delivery_stream.datadog.arn]
  }
}

## Kinesis Firehose
resource "aws_kinesis_firehose_delivery_stream" "datadog" {
  name        = "datadog"
  destination = "http_endpoint"

  http_endpoint_configuration {
    name               = "Datadog"
    access_key         = var.datadog_api_key
    buffering_interval = var.datadog_buffering_interval_seconds
    buffering_size     = 4  # MB
    retry_duration     = 60 # seconds
    role_arn           = aws_iam_role.datadog_firehose.arn
    s3_backup_mode     = "FailedDataOnly"
    url                = var.datadog_firehose_endpoint

    cloudwatch_logging_options {
      enabled = false
    }

    processing_configuration {
      enabled = false
    }

    request_configuration {
      content_encoding = "GZIP"
    }

    s3_configuration {
      bucket_arn          = aws_s3_bucket.datadog_firehose_backup.arn
      buffering_interval  = 300 # seconds
      buffering_size      = 5   # MB
      compression_format  = "UNCOMPRESSED"
      error_output_prefix = "metrics/"
      role_arn            = aws_iam_role.datadog_firehose.arn

      cloudwatch_logging_options {
        enabled = false
      }
    }
  }

  server_side_encryption {
    enabled = false
  }
}

resource "aws_iam_role" "datadog_firehose" {
  name                = "datadog-firehose"
  assume_role_policy  = data.aws_iam_policy_document.datadog_firehose_assume_role.json
  managed_policy_arns = []

  inline_policy {
    name   = "s3-backup"
    policy = data.aws_iam_policy_document.datadog_firehose_s3_backup.json
  }
}

data "aws_iam_policy_document" "datadog_firehose_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["firehose.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "datadog_firehose_s3_backup" {
  statement {
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]

    resources = [aws_s3_bucket.datadog_firehose_backup.arn]
  }

  statement {
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = ["${aws_s3_bucket.datadog_firehose_backup.arn}/*"]
  }
}

## Kinesis Firehose - S3 error/backup bucket
resource "aws_s3_bucket" "datadog_firehose_backup" {
  bucket = "datadog-firehose-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_ownership_controls" "datadog_firehose_backup" {
  bucket = aws_s3_bucket.datadog_firehose_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "datadog_firehose_backup" {
  bucket = aws_s3_bucket.datadog_firehose_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
