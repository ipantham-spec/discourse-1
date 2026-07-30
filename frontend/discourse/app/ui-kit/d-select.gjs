import Component from "@glimmer/component";
import { hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { isNone } from "@ember/utils";
import { modifier } from "ember-modifier";
import { i18n } from "discourse-i18n";

export const NO_VALUE_OPTION = "__NONE__";

const claimSelectedAfterRender = modifier((element, [selected]) => {
  if (selected) {
    element.selected = true;
  }
});

export class DSelectOption extends Component {
  get value() {
    return isNone(this.args.value) ? NO_VALUE_OPTION : this.args.value;
  }

  get isSelected() {
    return this.args.selected === this.args.value;
  }

  <template>
    {{! https://github.com/emberjs/ember.js/issues/19115 }}
    <option
      class={{if
        this.isSelected
        "d-select__option --selected"
        "d-select__option"
      }}
      value={{this.value}}
      selected={{this.isSelected}}
      {{claimSelectedAfterRender this.isSelected}}
      ...attributes
    >
      {{yield}}
    </option>
  </template>
}

export default class DSelect extends Component {
  get htmlSelectValue() {
    const value = this.args.value;
    if (value === NO_VALUE_OPTION) {
      return NO_VALUE_OPTION;
    }
    if (isNone(value) || value === "") {
      return NO_VALUE_OPTION;
    }
    return value;
  }

  @action
  handleInput(event) {
    // if an option has no value, event.target.value will be the content of the option
    // this is why we use this magic value to represent no value
    this.args.onChange(
      event.target.value === NO_VALUE_OPTION ? undefined : event.target.value
    );
  }

  get hasSelectedValue() {
    return this.args.value && this.args.value !== NO_VALUE_OPTION;
  }

  get includeNone() {
    return this.args.includeNone ?? true;
  }

  <template>
    <select
      value={{this.htmlSelectValue}}
      ...attributes
      class="d-select"
      {{on "input" this.handleInput}}
    >
      {{#if this.includeNone}}
        <DSelectOption @value={{NO_VALUE_OPTION}}>
          {{#if @nonePlaceholder}}
            {{@nonePlaceholder}}
          {{else}}
            {{#if this.hasSelectedValue}}
              {{i18n "none_placeholder"}}
            {{else}}
              {{i18n "select_placeholder"}}
            {{/if}}
          {{/if}}
        </DSelectOption>
      {{/if}}

      {{yield
        (hash Option=(component DSelectOption selected=this.htmlSelectValue))
      }}
    </select>
  </template>
}
