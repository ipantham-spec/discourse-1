export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("custom-webhooks-overview", { path: "overview" });
  },
};
