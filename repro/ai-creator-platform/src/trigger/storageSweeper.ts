import { task } from "@trigger.dev/sdk/v3";
import { tigrisClient, backblazeClient } from "../utils/storageClient";

export const storageSweeper = task({
  id: "storage-sweeper",
  run: async () => {
    return { tigris: !!tigrisClient, backblaze: !!backblazeClient };
  },
});
