require "test_helper"

class FeatureRequestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    FactorySetting.delete_all
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "enqueues the next idea when a request finishes in automatic mode" do
    FactorySetting.current.update!(mode: "automatic")

    assert_enqueued_with(job: IdeaGenerationJob) do
      feature_requests(:one).update!(status: "done")
    end
  end

  test "does not enqueue the next idea when a request finishes in manual mode" do
    FactorySetting.current.update!(mode: "manual")

    assert_no_enqueued_jobs(only: IdeaGenerationJob) do
      feature_requests(:one).update!(status: "done")
    end
  end
end
