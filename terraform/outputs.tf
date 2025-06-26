output "ingest_bucket" {
  value = aws_s3_bucket.ingest.bucket
}

output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "refined_bucket" {
  value = aws_s3_bucket.refined.bucket
}
