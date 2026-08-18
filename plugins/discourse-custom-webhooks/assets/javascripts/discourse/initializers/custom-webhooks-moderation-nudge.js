import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

// Pre-publish text nudge. Before a post is saved, run a synchronous moderation
// check. If the text is flagged, warn the author and let them Edit or Post
// anyway (soft nudge). Any error fails open so composing is never hard-blocked.
export default {
  name: "custom-webhooks-moderation-nudge",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (
      !siteSettings.custom_webhooks_enabled ||
      !siteSettings.custom_webhooks_check_text
    ) {
      return;
    }

    const dialog = container.lookup("service:dialog");

    withPluginApi((api) => {
      api.composerBeforeSave(function () {
        const composer = this;

        // The author already chose "Post anyway" for this attempt.
        if (composer._customWebhooksModerationOverride) {
          return Promise.resolve();
        }

        return ajax("/custom-webhooks/moderation/check", {
          type: "POST",
          data: { title: composer.title, raw: composer.reply },
        })
          .then((result) => {
            if (!result || result.can_publish !== false) {
              return Promise.resolve();
            }

            const message =
              result.nudge_message ||
              i18n("custom_webhooks.moderation.nudge.default_message");

            return new Promise((resolve, reject) => {
              dialog.confirm({
                message,
                confirmButtonLabel:
                  "custom_webhooks.moderation.nudge.post_anyway",
                cancelButtonLabel: "custom_webhooks.moderation.nudge.edit",
                didConfirm: () => {
                  composer._customWebhooksModerationOverride = true;
                  resolve();
                },
                didCancel: () => reject(),
              });
            });
          })
          .catch(() => Promise.resolve());
      });
    });
  },
};
