# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
describe "Custom webhooks" do
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: user, title: "A topic about webhooks") }
  fab!(:target_post) { Fabricate(:post, topic: topic, user: user, raw: "hello webhook world") }

  before do
    SiteSetting.custom_webhooks_enabled = true
    SiteSetting.custom_webhooks_payload_url = "https://hooks.example.com/incoming"
    SiteSetting.custom_webhooks_secret = "shhh"
    SiteSetting.custom_webhooks_callback_secret = "callback-secret"
    SiteSetting.custom_webhooks_events = "post_created|post_edited|topic_created"
  end

  describe DiscourseCustomWebhooks::Signature do
    it "signs with the sha256= prefix and verifies constant-time" do
      sig = described_class.sign("body", "secret")
      expect(sig).to start_with("sha256=")
      expect(described_class.valid?("body", "secret", sig)).to eq(true)
      expect(described_class.valid?("body", "secret", "sha256=bad")).to eq(false)
      expect(described_class.valid?("body", "", sig)).to eq(false)
    end
  end

  describe DiscourseCustomWebhooks::PayloadBuilder do
    it "builds a moderation event with actor identity, text and event_type" do
      payload = described_class.new(target_post, event: "post_created").build

      expect(payload[:event]).to eq("post_created")
      expect(payload[:event_type]).to eq("topic")
      expect(payload[:post_id]).to eq(target_post.id)
      expect(payload[:topic_id]).to eq(topic.id)
      expect(payload[:text][:title]).to eq(topic.title)
      expect(payload[:text][:raw]).to eq("hello webhook world")
      expect(payload[:actor][:username]).to eq(user.username)
      expect(payload[:has_images]).to eq(false)
      expect(payload[:images]).to eq([])
      expect(payload[:callback_url]).to eq(
        "#{Discourse.base_url}/custom-webhooks/moderation/callback",
      )
    end

    it "uses event_type reply and omits the title for replies" do
      reply = Fabricate(:post, topic: topic, user: user)
      payload = described_class.new(reply, event: "post_created").build
      expect(payload[:event_type]).to eq("reply")
      expect(payload[:text][:title]).to be_nil
    end

    it "resolves the actor sso_id from the configured SSO provider" do
      SiteSetting.custom_webhooks_sso_provider = "oidc"
      UserAssociatedAccount.create!(
        provider_name: "oidc",
        provider_uid: "1002920570207",
        user: user,
      )

      payload = described_class.new(target_post, event: "post_created").build
      expect(payload[:actor][:sso_id]).to eq("1002920570207")
    end

    it "omits sso_id when no linked account exists" do
      payload = described_class.new(target_post, event: "post_created").build
      expect(payload[:actor][:sso_id]).to be_nil
    end
  end

  describe DiscourseCustomWebhooks::Emitter do
    it "is enabled only when turned on and a url is set" do
      expect(described_class.enabled?).to eq(true)
      SiteSetting.custom_webhooks_payload_url = ""
      expect(described_class.enabled?).to eq(false)
    end

    it "reports subscription based on the configured event list" do
      expect(described_class.subscribed?("post_created")).to eq(true)
      SiteSetting.custom_webhooks_events = "post_edited"
      expect(described_class.subscribed?("post_created")).to eq(false)
      expect(described_class.subscribed?("post_edited")).to eq(true)
    end

    it "signs the request body and posts to the endpoint" do
      captured = nil
      stub_request(:post, SiteSetting.custom_webhooks_payload_url)
        .to_return(status: 200)
        .with { |req| captured = req }

      payload = { event: "post_created", post_id: target_post.id }
      described_class.deliver(payload)

      body = payload.to_json
      expected = DiscourseCustomWebhooks::Signature.sign(body, "shhh")
      expect(captured.headers["X-Discourse-Signature"]).to eq(expected)
      expect(captured.body).to eq(body)
    end

    it "uses a custom signature header name when configured" do
      SiteSetting.custom_webhooks_signature_header = "X-Hub-Signature-256"
      captured = nil
      stub_request(:post, SiteSetting.custom_webhooks_payload_url)
        .to_return(status: 200)
        .with { |req| captured = req }

      described_class.deliver({ a: 1 })
      expect(captured.headers["X-Hub-Signature-256"]).to be_present
    end

    it "adds configured static headers" do
      SiteSetting.custom_webhooks_extra_headers = "X-Env: staging|X-Team: forums"
      captured = nil
      stub_request(:post, SiteSetting.custom_webhooks_payload_url)
        .to_return(status: 200)
        .with { |req| captured = req }

      described_class.deliver({ a: 1 })
      expect(captured.headers["X-Env"]).to eq("staging")
      expect(captured.headers["X-Team"]).to eq("forums")
    end

    it "fails open when the endpoint errors" do
      stub_request(:post, SiteSetting.custom_webhooks_payload_url).to_raise(
        Faraday::ConnectionFailed.new("boom"),
      )
      expect { described_class.deliver({ a: 1 }) }.not_to raise_error
    end

    it "does not deliver when disabled" do
      SiteSetting.custom_webhooks_enabled = false
      described_class.deliver({ a: 1 })
      expect(WebMock).not_to have_requested(:post, SiteSetting.custom_webhooks_payload_url)
    end
  end

  describe "event hooks (async path = image posts only)" do
    it "does not enqueue async for a text-only post (text is gated inline)" do
      SiteSetting.custom_webhooks_include_images = true
      expect_not_enqueued_with(job: :custom_webhooks_emit_event) do
        PostCreator.create!(user, title: "Text only topic here", raw: "no image, just words")
      end
    end

    it "enqueues async for a post that has an image" do
      SiteSetting.custom_webhooks_include_images = true
      DiscourseCustomWebhooks::Emitter.stubs(:post_has_image?).returns(true)
      expect_enqueued_with(job: :custom_webhooks_emit_event) do
        PostCreator.create!(user, title: "Image topic title here", raw: "look at this image")
      end
    end

    it "does not enqueue for an event that is not subscribed" do
      SiteSetting.custom_webhooks_events = "post_edited"
      SiteSetting.custom_webhooks_include_images = true
      DiscourseCustomWebhooks::Emitter.stubs(:post_has_image?).returns(true)
      expect_not_enqueued_with(job: :custom_webhooks_emit_event) do
        PostCreator.create!(user, title: "No hook topic title here", raw: "no webhook please")
      end
    end

    it "does not enqueue when image scanning is disabled" do
      SiteSetting.custom_webhooks_include_images = false
      DiscourseCustomWebhooks::Emitter.stubs(:post_has_image?).returns(true)
      expect_not_enqueued_with(job: :custom_webhooks_emit_event) do
        PostCreator.create!(
          user,
          title: "Images disabled topic",
          raw: "has an image but scanning off",
        )
      end
    end
  end

  describe Jobs::CustomWebhooksEmitEvent do
    it "delivers the built payload for the post" do
      stub = stub_request(:post, SiteSetting.custom_webhooks_payload_url).to_return(status: 200)
      described_class.new.execute(post_id: target_post.id, event: "post_created")
      expect(stub).to have_been_requested
    end

    it "is a no-op when the event is not subscribed" do
      SiteSetting.custom_webhooks_events = "post_edited"
      described_class.new.execute(post_id: target_post.id, event: "post_created")
      expect(WebMock).not_to have_requested(:post, SiteSetting.custom_webhooks_payload_url)
    end
  end

  describe "verdict callback", type: :request do
    def post_verdict(body)
      json = body.to_json
      sig = DiscourseCustomWebhooks::Signature.sign(json, "callback-secret")
      post "/custom-webhooks/moderation/callback",
           params: json,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_FORUMS_SIGNATURE" => sig,
           }
    end

    it "returns 401 for an invalid signature" do
      post "/custom-webhooks/moderation/callback",
           params: { event_id: "x", post_id: target_post.id }.to_json,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "HTTP_X_FORUMS_SIGNATURE" => "sha256=bad",
           }
      expect(response.status).to eq(401)
    end

    it "returns 404 when the plugin moderation is disabled" do
      SiteSetting.custom_webhooks_enabled = false
      post_verdict({ event_id: "e", post_id: target_post.id })
      expect(response.status).to eq(404)
    end

    it "publishes a post on a clean verdict" do
      target_post.hide!(PostActionType.types[:inappropriate])
      post_verdict(
        {
          event_id: "evt-clean",
          post_id: target_post.id,
          results: {
            image: {
              verdict: "CLEAN",
            },
          },
        },
      )
      expect(response.status).to eq(200)
      expect(response.parsed_body["action"]).to eq("published")
      expect(target_post.reload.hidden).to eq(false)
    end

    it "raises a reviewable and keeps a text violation hidden" do
      expect {
        post_verdict(
          {
            event_id: "evt-text",
            post_id: target_post.id,
            moderation_id: "mod-1",
            results: {
              text: {
                violation_found: true,
                category: "PROFANITY",
                severity: "high",
                confidence: 0.97,
                flagged_terms: %w[badword1 badword2],
                reasons: %w[profanity],
                reasoning: "Explicit profanity.",
              },
            },
          },
        )
      }.to change { ReviewableCustomWebhooksModeration.count }.by(1)

      expect(response.parsed_body["action"]).to eq("review")
      expect(target_post.reload.hidden).to eq(true)

      payload = ReviewableCustomWebhooksModeration.last.payload
      expect(payload["category"]).to eq("PROFANITY")
      expect(payload["severity"]).to eq("high")
      expect(payload["flagged_terms"]).to eq(%w[badword1 badword2])
      expect(payload["reasoning"]).to eq("Explicit profanity.")
    end

    it "destroys a CSAM public post" do
      post_verdict(
        { event_id: "evt-csam", post_id: target_post.id, results: { image: { verdict: "CSAM" } } },
      )
      expect(response.parsed_body["action"]).to eq("destroyed")
      expect(Post.with_deleted.find(target_post.id).deleted_at).not_to be_nil
    end

    it "is idempotent on a replayed event_id" do
      body = {
        event_id: "evt-dupe",
        post_id: target_post.id,
        results: {
          image: {
            verdict: "CLEAN",
          },
        },
      }
      post_verdict(body)
      expect(response.parsed_body["action"]).to eq("published")
      post_verdict(body)
      expect(response.parsed_body["status"]).to eq("noop")
    end

    it "returns 404 for an unknown post" do
      post_verdict({ event_id: "evt-x", post_id: 0, results: { image: { verdict: "CLEAN" } } })
      expect(response.status).to eq(404)
    end
  end

  describe "reviewable actions" do
    fab!(:moderator)

    def build_reviewable
      target_post.hide!(PostActionType.types[:inappropriate])
      ReviewableCustomWebhooksModeration.needs_review!(
        target: target_post,
        topic: target_post.topic,
        created_by: Discourse.system_user,
        reviewable_by_moderator: true,
        payload: {
          "source" => "DISCOURSE",
          "category" => "PROFANITY",
        },
      )
    end

    it "publishes the post when a moderator disagrees" do
      reviewable = build_reviewable
      reviewable.perform(moderator, :disagree_and_publish)
      expect(target_post.reload.hidden).to eq(false)
      expect(reviewable.reload.status).to eq("rejected")
    end

    it "keeps the post hidden when a moderator agrees" do
      reviewable = build_reviewable
      reviewable.perform(moderator, :agree_and_keep_hidden)
      expect(target_post.reload.hidden).to eq(true)
      expect(reviewable.reload.status).to eq("approved")
    end
  end

  describe ReviewableCustomWebhooksModerationSerializer do
    fab!(:moderator)

    it "exposes the moderation detail to the client" do
      reviewable =
        ReviewableCustomWebhooksModeration.needs_review!(
          target: target_post,
          topic: target_post.topic,
          created_by: Discourse.system_user,
          reviewable_by_moderator: true,
          payload: {
            "source" => "DISCOURSE",
            "category" => "PROFANITY",
            "subtype" => "profanity",
            "severity" => "high",
            "confidence" => 0.97,
            "flagged_terms" => %w[badword1 badword2],
            "reasons" => %w[profanity],
            "reasoning" => "Explicit profanity.",
            "moderation_id" => "mod-prof-1",
          },
        )

      json = described_class.new(reviewable, root: false, scope: Guardian.new(moderator)).as_json

      expect(json[:category]).to eq("PROFANITY")
      expect(json[:severity]).to eq("high")
      expect(json[:confidence]).to eq(0.97)
      expect(json[:flagged_terms]).to eq(%w[badword1 badword2])
      expect(json[:reasoning]).to eq("Explicit profanity.")
      expect(json[:moderation_id]).to eq("mod-prof-1")
    end
  end

  describe "text check endpoint", type: :request do
    fab!(:signed_in_user) { Fabricate(:user, refresh_auto_groups: true) }

    before do
      SiteSetting.custom_webhooks_text_check_url = "https://mod.example.com/text/check"
      sign_in(signed_in_user)
    end

    it "returns the pipeline verdict for flagged text" do
      stub_request(:post, SiteSetting.custom_webhooks_text_check_url).to_return(
        status: 200,
        body: {
          results: {
            text: {
              can_publish: false,
              nudge_message: "Please rephrase",
              category: "PROFANITY",
            },
          },
        }.to_json,
      )

      post "/custom-webhooks/moderation/check.json", params: { title: "t", raw: "bad words" }

      expect(response.status).to eq(200)
      expect(response.parsed_body["can_publish"]).to eq(false)
      expect(response.parsed_body["nudge_message"]).to eq("Please rephrase")
    end

    it "fails open when the endpoint errors" do
      stub_request(:post, SiteSetting.custom_webhooks_text_check_url).to_return(status: 500)
      post "/custom-webhooks/moderation/check.json", params: { title: "t", raw: "hello" }
      expect(response.parsed_body["can_publish"]).to eq(true)
    end

    it "fails open when no check URL is configured" do
      SiteSetting.custom_webhooks_text_check_url = ""
      post "/custom-webhooks/moderation/check.json", params: { title: "t", raw: "hello" }
      expect(response.parsed_body["can_publish"]).to eq(true)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
