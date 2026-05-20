# file ko memory me temporarily store karne ke liye
import io

# file handling ke liye
import os

# current date lene ke liye
from datetime import datetime

# aws connect karne ke liye
import boto3

# aws error handle karne ke liye
from botocore.exceptions import ClientError

# google drive authentication
from google.oauth2 import service_account

# google drive api build karne ke liye
from googleapiclient.discovery import build

# drive file download karne ke liye
from googleapiclient.http import MediaIoBaseDownload


# google drive access scope
SCOPES = ['https://www.googleapis.com/auth/drive']

# service account file
SERVICE_ACCOUNT_FILE = 'service-account.json'

# google drive folder id
FOLDER_ID = "1Wyp4u-uln2dtXC63O2hqN8PBqir6SOoz"

# s3 bucket name
BUCKET_NAME = "global-data-mart-bucket"

# dynamodb table
DYNAMODB_TABLE = "file_upload_status"


# google authentication
credentials = service_account.Credentials.from_service_account_file(
    SERVICE_ACCOUNT_FILE,
    scopes=SCOPES
)

# google drive service
service = build('drive', 'v3', credentials=credentials)

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
# taaki DOWNLOADING, UPLOADING, UPLOADED sab alag alag dikhe

def update_status(file_id, file_name, status, s3_path=""):

    table.put_item(
        Item={

            # unique row key
            "file_id": f"{file_id}_{datetime.now().timestamp()}",

            # original google drive id
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
print("GOOGLE DRIVE TO S3 AUTOMATION")
print("====================================")


# ye script sirf ek baar chalegi
# baar baar polling nahi karegi
# automatic run cron job se hoga

try:

    print("\nChecking Google Drive Folder...")

    # drive folder se files fetch
    results = service.files().list(

        q=f"'{FOLDER_ID}' in parents and trashed=false",

        fields="files(id, name)"

    ).execute()

    # files list
    files = results.get('files', [])

    # agar file nahi hai
    if not files:

        print("No new files found.")

    # har file process karo
    for file in files:

        # file id
        file_id = file['id']

        # file name
        file_name = file['name']

        print(f"\nProcessing File: {file_name}")

        # file extension
        extension = os.path.splitext(file_name)[1].lower()

        # agar extension nahi hai
        if extension == "":

            extension = ".others"

        # dot remove
        folder_name = extension.replace(".", "")

        # current date
        current_date = datetime.now().strftime("%Y-%m-%d")

        # final s3 path
        s3_key = f"{folder_name}/{current_date}/{file_name}"

        # duplicate file check
        if file_exists_in_s3(BUCKET_NAME, s3_key):

            print(f"File Already Exists: {file_name}")

            # already exists status
            update_status(
                file_id,
                file_name,
                "ALREADY_EXISTS",
                s3_key
            )

            continue

        # downloading status
        # file drive se fetch ho rahi hai
        update_status(
            file_id,
            file_name,
            "DOWNLOADING"
        )

        # drive file download
        request = service.files().get_media(
            fileId=file_id
        )

        # memory buffer
        file_data = io.BytesIO()

        # downloader object
        downloader = MediaIoBaseDownload(
            file_data,
            request
        )

        done = False

        # chunk wise download
        while done is False:

            status, done = downloader.next_chunk()

        # local save
        with open(file_name, 'wb') as f:

            f.write(file_data.getvalue())

        print(f"Downloaded: {file_name}")

        # uploading status
        # s3 upload start
        update_status(
            file_id,
            file_name,
            "UPLOADING"
        )

        # s3 upload
        s3.upload_file(

            file_name,

            BUCKET_NAME,

            s3_key
        )

        print(f"Uploaded To S3: {s3_key}")

        # uploaded status
        # successful upload
        update_status(
            file_id,
            file_name,
            "UPLOADED",
            s3_key
        )

        # local file delete
        # storage clean rakhne ke liye
        os.remove(file_name)

        print(f"Local File Deleted: {file_name}")

        # deleted status
        # local cleanup completed
        update_status(
            file_id,
            file_name,
            "DELETED",
            s3_key
        )

# error handling
except Exception as e:

    print(f"\nERROR: {str(e)}")