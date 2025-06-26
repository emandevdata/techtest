import boto3
import csv
import os
import io
import re
import logging
from datetime import datetime

# Logging setup
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients and env vars
s3 = boto3.client("s3")
RAW_BUCKET = os.environ["RAW_BUCKET"]
REFINED_BUCKET = os.environ["REFINED_BUCKET"]

EMAIL_REGEX = re.compile(r"^[\w\.-]+@[\w\.-]+\.\w+$")


def lambda_handler(event, context):
    record = event["Records"][0]
    source_bucket = record["s3"]["bucket"]["name"]
    object_key = record["s3"]["object"]["key"]

    logger.info(f"Triggered by file: {object_key} in bucket: {source_bucket}")

    # Step 1: Copy to raw bucket
    copy_source = {"Bucket": source_bucket, "Key": object_key}
    try:
        s3.copy_object(CopySource=copy_source, Bucket=RAW_BUCKET, Key=object_key)
        logger.info(f"Copied to raw bucket: {RAW_BUCKET}/{object_key}")
    except Exception as e:
        logger.error(f"Failed to copy to raw bucket: {e}")
        return

    # Step 2: Read and clean
    try:
        response = s3.get_object(Bucket=source_bucket, Key=object_key)
        content = response["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(content))
    except Exception as e:
        logger.error(f"Error reading S3 object: {e}")
        return

    cleaned_rows = []
    rejected_rows = []

    for row in reader:
        try:
            cleaned = {
                "id": row["id"].strip(),
                "name": row["name"].strip(),
                "email": row["email"].strip().lower(),
                "create_ts": row["create_ts"].strip(),
                "update_ts": row["update_ts"].strip(),
            }

            if cleaned["update_ts"] >= cleaned["create_ts"] and EMAIL_REGEX.match(
                cleaned["email"]
            ):
                cleaned_rows.append(cleaned)
            else:
                rejected_rows.append(cleaned)
        except Exception as e:
            logger.warning(f"Malformed row: {e}")
            rejected_rows.append(row)

    # Prepare partitioned path
    now = datetime.utcnow()
    date_str = now.strftime("date=%Y-%m-%d")
    hour_str = now.strftime("hour=%H")

    base_path = f"{date_str}/{hour_str}/"
    base_filename = os.path.basename(object_key).replace(".csv", "")

    # Step 3: Write cleaned rows
    if cleaned_rows:
        output_key = f"{base_path}{base_filename}_cleaned.csv"
        out_stream = io.StringIO()
        fieldnames = cleaned_rows[0].keys()
        writer = csv.DictWriter(out_stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(cleaned_rows)

        try:
            s3.put_object(
                Bucket=REFINED_BUCKET,
                Key=f"refined/{output_key}",
                Body=out_stream.getvalue().encode("utf-8"),
            )
            logger.info(f"Cleaned file saved to: refined/{output_key}")
        except Exception as e:
            logger.error(f"Error writing cleaned file: {e}")

    # Step 4: Write rejected rows
    if rejected_rows:
        reject_key = f"{base_path}rejected/{base_filename}_rejected.csv"
        reject_stream = io.StringIO()
        writer = csv.DictWriter(reject_stream, fieldnames=rejected_rows[0].keys())
        writer.writeheader()
        writer.writerows(rejected_rows)

        try:
            s3.put_object(
                Bucket=REFINED_BUCKET,
                Key=f"refined/{reject_key}",
                Body=reject_stream.getvalue().encode("utf-8"),
            )
            logger.info(f"Rejected file saved to: refined/{reject_key}")
        except Exception as e:
            logger.error(f"Error writing rejected file: {e}")
