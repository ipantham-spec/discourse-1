import { LinkTo } from "@ember/routing";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default <template>
  <section class="admin-detail custom-webhooks-overview">
    <div class="admin-config-area">
      <div class="admin-config-area__primary-content">
        <div class="admin-config-area-card">
          <h2>{{i18n "custom_webhooks.admin.overview.title"}}</h2>
          <p>{{i18n "custom_webhooks.admin.overview.description"}}</p>

          <ul class="custom-webhooks-overview__points">
            <li>{{dIcon "paper-plane"}}
              {{i18n "custom_webhooks.admin.overview.point_events"}}</li>
            <li>{{dIcon "lock"}}
              {{i18n "custom_webhooks.admin.overview.point_signing"}}</li>
            <li>{{dIcon "certificate"}}
              {{i18n "custom_webhooks.admin.overview.point_mtls"}}</li>
          </ul>

          <LinkTo
            @route="adminPlugins.show.settings"
            class="btn btn-primary custom-webhooks-overview__configure"
          >
            {{dIcon "gear"}}
            {{i18n "custom_webhooks.admin.overview.configure"}}
          </LinkTo>
        </div>
      </div>
    </div>
  </section>
</template>
