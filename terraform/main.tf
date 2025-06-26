provider "aws" {
  region = "us-east-1"
}

#--------------------------------------------------------------------
# S3
#--------------------------------------------------------------------
# S3 Bucket for receiving external files
resource "aws_s3_bucket" "ingest" {
  bucket = "techtest-ingest-bucket"
  force_destroy = true
}

# S3 Bucket for raw data
resource "aws_s3_bucket" "raw" {
  bucket = "techtest-raw-data-bucket"
  force_destroy = true
}

# S3 Bucket for refined (or transformed) data
resource "aws_s3_bucket" "refined" {
  bucket = "techtest-refined-data-bucket"
  force_destroy = true
}


#--------------------------------------------------------------------
# LAMBDA
#--------------------------------------------------------------------

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "techtest_lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach basic Lambda logging permission to CloudWatch
resource "aws_iam_policy_attachment" "lambda_logs" {
  name       = "lambda_logs"
  roles      = [aws_iam_role.lambda_exec_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Policy to select the right access
resource "aws_iam_policy" "lambda_s3_limited" {
  name        = "techtest_lambda_s3_limited"
  description = "Limited access to techtest S3 buckets"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = "arn:aws:s3:::techtest-ingest-bucket/*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "arn:aws:s3:::techtest-raw-data-bucket/*",
          "arn:aws:s3:::techtest-refined-data-bucket/*"
        ]
      }
    ]
  })
}

# Attach policy to IAM role fro Lambda (so we have the right permssions)
resource "aws_iam_policy_attachment" "lambda_s3_limited_attach" {
  name       = "lambda_s3_limited_attach"
  roles      = [aws_iam_role.lambda_exec_role.name]
  policy_arn = aws_iam_policy.lambda_s3_limited.arn
}

# Define the lambda function
resource "aws_lambda_function" "process_file" {
  function_name = "process_file_lambda"
  handler       = "process_file.lambda_handler"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_exec_role.arn

  filename         = "../build/lambda_function_process_file.zip" 
  source_code_hash = filebase64sha256("../build/lambda_function_process_file.zip")

  environment {
    variables = {
      RAW_BUCKET     = aws_s3_bucket.raw.bucket
      REFINED_BUCKET = aws_s3_bucket.refined.bucket
    }
  }
}

# Allow S3 to invoke Lambda
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_file.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.ingest.arn
}

# Set up S3 event trigger
resource "aws_s3_bucket_notification" "ingest_trigger" {
  bucket = aws_s3_bucket.ingest.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_file.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}