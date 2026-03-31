# Testing UseCases: 

- **Basic Task Operations**                                                               Status

    1. Add a LOW priority task and verify it appears in the CSV file.                       ✅
    2. Add a task with a long description to test character limits                          ✅
    3. Complete a task and confirm its status updates in the CSV                            ✅
    4. Delete a task and verify it is removed from the local file                           ✅
    5. List all tasks and confirm the output is sorted correctly                            ✅

- **Priority & Alerts**

    1. Add a HIGH priority task and confirm SNS alert is fired immediately                  ✅
    2. Add a MEDIUM priority task and confirm no SNS alert is triggered                     ✅
    3. Change a task from LOW to HIGH and verify SNS fires on update                        ❌
    4. Add multiple HIGH priority tasks back-to-back and confirm all alerts are sent        ✅

- **S3 Backup**

    1. Add a task and verify the CSV backup appears in the S3 bucket                        ✅
    2. Complete a task and confirm the updated CSV is re-uploaded to S3                     ✅
    3. Delete a task and check the latest S3 object reflects the change                     ✅
    4. Simulate an S3 outage and confirm the CLI still writes locally without crashing      ✅
    5. Check S3 versioning to confirm previous backup versions are retained                 ✅

- **CloudWatch Logging**

    1. Add a task and verify the structured log entry appears in CloudWatch Logs            ✅
    2. Query CloudWatch Logs Insights for all HIGH priority tasks added today               ✅
    3. Confirm log entries include timestamp, task ID, priority, and action type            ✅
    4. Trigger an error (e.g. bad input) and confirm it is captured in the logs             ✅

- **CloudWatch Metrics**

    1. Add three tasks and verify TasksAdded metric increments by three
    2. Complete two tasks and confirm TasksCompleted metric reflects the count
    3. Check the CloudWatch dashboard updates in near real time after each action

- **IAM & Security**

    1. Run Cloudtask with a role missing S3 permissions and confirm a clean error message
    2. Run with a role missing SNS permissions and confirm HIGH priority task still saves locally
    3. Confirm no credentials are logged or printed anywhere in the CLI output
    4. Verify the S3 bucket rejects direct public access attempts

- **Compatibility**

    1. Run Cloudtask on Linux, macOS, and Windows WSL and confirm consistent behavior
    2. Switch AWS profiles using AWS_PROFILE and verify the correct S3 bucket is used
    3. Run in a different AWS region and confirm logs appear in the correct CloudWatch region

- **Edge Cases**

    1. Add a task with an empty description and confirm validation catches it
    2. Add 100 tasks rapidly and confirm all are backed up to S3 without missing entries
    3. Run two Cloudtask instances simultaneously and check for CSV write conflicts
    4. Delete a task that does not exist and confirm a graceful error is returned
    5. Start Cloudtask with no internet connection and confirm local CSV still works
