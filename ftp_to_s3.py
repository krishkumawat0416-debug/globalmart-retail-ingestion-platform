# local folder access ke liye
import os

# current date lene ke liye
from datetime import datetime

# aws connect karne ke liye
import boto3

# aws error handle karne ke liye
from botocore.exceptions import ClientError


# ftp folder path
FTP_FOLDER = "/home/ubuntu/ftp_files"

# s3 bucket name
BUCKET_NAME = "global-data-mart-bucket"

# dynamodb table
DYNAMODB_TABLE = "file_upload_status"


# s3 client
s3 = boto3.client('s3')

# dynamodb resource
dynamodb = boto3.resource('dynamodb')

# dynamodb table connect
table = dynamodb.Table(DYNAMODB_TABLE)


# file already s3 me hai ya nahi
def file_exists_in_s3(bucket, key):

    try:

        s3.head_object(
            Bucket=bucket,
            Key=key
        )

        return True

    except ClientError:

        return False


# dynamodb me har status ka alag record save hoga
# isliye timestamp ko unique key bana rahe hai
# taaki UPLOADING, UPLOADED sab alag alag dikhe

def update_status(file_id, file_name, status, s3_path=""):

    table.put_item(
        Item={

            # unique row key
            "file_id": f"{file_id}_{datetime.now().timestamp()}",

            # original file id
            "original_file_id": file_id,

            # file name
            "file_name": file_name,

            # current status
            "status": status,

            # s3 path
            "s3_path": s3_path,

            # update time
            "updated_at": str(datetime.now())
        }
    )


print("====================================")
print("FTP TO S3 AUTOMATION")
print("====================================")


# ye script sirf ek baar chalegi
# automatic run cron job se hoga

try:

    print("\nChecking FTP Folder...")

    # ftp folder files
    files = os.listdir(FTP_FOLDER)

    # agar file nahi hai
    if not files:

        print("No new files found.")

    # har file process karo
    for file_name in files:

        print(f"\nProcessing File: {file_name}")

        # file extension
        extension = os.path.splitext(file_name)[1].lower()

        # sirf csv aur parquet allow
        if extension not in [".csv", ".parquet"]:

            print(f"Skipped (Not CSV/Parquet): {file_name}")

            # skipped status
            update_status(
                file_name,
                file_name,
                "SKIPPED_INVALID_FILE"
            )

            continue

        # current date
        current_date = datetime.now().strftime("%Y-%m-%d")

        # extension folder
        folder_name = extension.replace(".", "")

        # final s3 path
        s3_key = f"ftp/{folder_name}/{current_date}/{file_name}"

        # duplicate file check
        if file_exists_in_s3(BUCKET_NAME, s3_key):

            print(f"File Already Exists: {file_name}")

            # already exists status
            update_status(
                file_name,
                file_name,
                "ALREADY_EXISTS",
                s3_key
            )

            continue

        # uploading status
        update_status(
            file_name,
            file_name,
            "UPLOADING"
        )

        # local file path
        local_file_path = os.path.join(
            FTP_FOLDER,
            file_name
        )

        # s3 upload
        s3.upload_file(

            local_file_path,

            BUCKET_NAME,

            s3_key
        )

        print(f"Uploaded To S3: {s3_key}")

        # uploaded status
        update_status(
            file_name,
            file_name,
            "UPLOADED",
            s3_key
        )

        # local file delete
        # storage clean rakhne ke liye
        os.remove(local_file_path)

        print(f"Local File Deleted: {file_name}")

        # deleted status
        update_status(
            file_name,
            file_name,
            "DELETED",
            s3_key
        )

# error handling
except Exception as e:

    print(f"\nERROR: {str(e)}")