import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-custom-webhooks";

export default {
  name: "custom-webhooks-admin-plugin-configuration-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon(PLUGIN_ID, "paper-plane");
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          label: "custom_webhooks.admin.overview.nav_label",
          route: "adminPlugins.show.custom-webhooks-overview",
          description: "custom_webhooks.admin.overview.nav_description",
        },
      ]);
    });
  },
};
