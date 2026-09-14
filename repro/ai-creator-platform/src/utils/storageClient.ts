import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

export const tigrisClient = new S3Client({
  region: "auto",
  endpoint: "https://fly.storage.tigris.dev",
});

export const backblazeClient = new S3Client({
  region: "us-west-004",
  endpoint: "https://s3.us-west-004.backblazeb2.com",
});

export async function uploadToTigris(key: string, body: Uint8Array): Promise<string> {
  await tigrisClient.send(
    new PutObjectCommand({ Bucket: "hot", Key: key, Body: body })
  );
  return key;
}
