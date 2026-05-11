require "test_helper"

class FeatureRequestsRetryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "resets a failed feature request to todo and enqueues the factory job" do
    fr = feature_requests(:failed_one)

    assert_enqueued_with(job: DarkFactoryJob, args: [ fr.id ]) do
      post retry_feature_request_url(fr)
    end

    fr.reload
    assert_equal "todo", fr.status
    assert_nil fr.failure_reason
    assert_nil fr.branch_name
    assert_equal false, fr.feedback_addressed
    assert_nil fr.last_review_seen_at
    assert_nil fr.landed_commit_sha
    assert_nil fr.review_verdict
    assert_nil fr.review_body
    assert_nil fr.stop_requested_at
  end

  test "redirects to the feature request show page after retry" do
    fr = feature_requests(:failed_one)

    post retry_feature_request_url(fr)

    assert_redirected_to feature_request_url(fr)
  end

  test "returns 422 when feature request is not failed" do
    fr = feature_requests(:one)

    assert_no_enqueued_jobs only: DarkFactoryJob do
      post retry_feature_request_url(fr)
    end

    assert_response :unprocessable_entity
  end

  test "retries automatic idea generation failures with the idea job" do
    fr = feature_requests(:failed_idea)

    assert_enqueued_with(job: IdeaGenerationJob) do
      assert_no_enqueued_jobs only: DarkFactoryJob do
        post retry_feature_request_url(fr)
      end
    end

    assert_redirected_to root_url
    assert_equal "failed", fr.reload.status
  end
end
