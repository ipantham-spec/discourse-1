import ReviewablePost from "discourse/components/reviewable/post";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

const SEVERITY_ICONS = {
  low: "circle-info",
  medium: "triangle-exclamation",
  high: "circle-exclamation",
  critical: "circle-exclamation",
};

function severityIcon(severity) {
  return SEVERITY_ICONS[(severity || "").toLowerCase()] || "flag";
}

function confidencePercent(confidence) {
  if (confidence === null || confidence === undefined) {
    return null;
  }
  const value = confidence <= 1 ? confidence * 100 : confidence;
  return `${Math.round(value)}%`;
}

// Moderation review item. Reuses the core post renderer and yields a details
// panel that mirrors the information the moderation pipeline surfaces: category,
// subtype, severity, confidence, the flagged terms and the model's reasoning.
export default <template>
  <ReviewablePost @reviewable={{@reviewable}}>
    <div class="custom-webhooks-moderation-details">
      <div class="custom-webhooks-moderation-details__header">
        {{dIcon (severityIcon @reviewable.severity)}}
        <span class="custom-webhooks-moderation-details__title">
          {{i18n "custom_webhooks.reviewable.details.title"}}
        </span>
        {{#if @reviewable.source}}
          <span class="custom-webhooks-moderation-details__source">
            {{@reviewable.source}}
          </span>
        {{/if}}
      </div>

      <dl class="custom-webhooks-moderation-details__grid">
        {{#if @reviewable.category}}
          <div class="custom-webhooks-moderation-details__row">
            <dt>{{i18n "custom_webhooks.reviewable.details.category"}}</dt>
            <dd
              class="custom-webhooks-moderation-details__category"
            >{{@reviewable.category}}</dd>
          </div>
        {{/if}}

        {{#if @reviewable.subtype}}
          <div class="custom-webhooks-moderation-details__row">
            <dt>{{i18n "custom_webhooks.reviewable.details.subtype"}}</dt>
            <dd>{{@reviewable.subtype}}</dd>
          </div>
        {{/if}}

        {{#if @reviewable.severity}}
          <div class="custom-webhooks-moderation-details__row">
            <dt>{{i18n "custom_webhooks.reviewable.details.severity"}}</dt>
            <dd
              class="custom-webhooks-moderation-details__severity --{{@reviewable.severity}}"
            >{{@reviewable.severity}}</dd>
          </div>
        {{/if}}

        {{#if @reviewable.confidence}}
          <div class="custom-webhooks-moderation-details__row">
            <dt>{{i18n "custom_webhooks.reviewable.details.confidence"}}</dt>
            <dd>{{confidencePercent @reviewable.confidence}}</dd>
          </div>
        {{/if}}
      </dl>

      {{#if @reviewable.flagged_terms.length}}
        <div class="custom-webhooks-moderation-details__terms">
          <span class="custom-webhooks-moderation-details__label">
            {{i18n "custom_webhooks.reviewable.details.flagged_terms"}}
          </span>
          {{#each @reviewable.flagged_terms as |term|}}
            <span
              class="custom-webhooks-moderation-details__term"
            >{{term}}</span>
          {{/each}}
        </div>
      {{/if}}

      {{#if @reviewable.reasons.length}}
        <div class="custom-webhooks-moderation-details__reasons">
          <span class="custom-webhooks-moderation-details__label">
            {{i18n "custom_webhooks.reviewable.details.reasons"}}
          </span>
          {{#each @reviewable.reasons as |reason|}}
            <span
              class="custom-webhooks-moderation-details__reason"
            >{{reason}}</span>
          {{/each}}
        </div>
      {{/if}}

      {{#if @reviewable.reasoning}}
        <div class="custom-webhooks-moderation-details__reasoning">
          <span class="custom-webhooks-moderation-details__label">
            {{i18n "custom_webhooks.reviewable.details.reasoning"}}
          </span>
          <p>{{@reviewable.reasoning}}</p>
        </div>
      {{/if}}

      {{#if @reviewable.moderation_id}}
        <div class="custom-webhooks-moderation-details__meta">
          {{i18n "custom_webhooks.reviewable.details.moderation_id"}}
          <code>{{@reviewable.moderation_id}}</code>
        </div>
      {{/if}}
    </div>
  </ReviewablePost>
</template>
