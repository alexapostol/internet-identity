import { html, render } from "lit-html";
import { warningIcon } from "../components/icons";
import { features } from "../features";

/** Run the specified function iff the "IS_MIGRATING" feature is not set.
 * This gates the functionality of 'f', but can be jailbroken by clicking the
 * icon 3 times.
 **/
export function unlessIsMigrating<T>(f: () => Promise<T>): Promise<T> {
  if (features.IS_MIGRATING) {
    return new Promise((resolve) => {
      render(pageContent(), document.getElementById("pageContent") as HTMLElement);

      const jailbreak = document.querySelector(
        'span[data-action="jailbreak"]'
      ) as HTMLElement;
      let jailbreakClickCount = 0;
      jailbreak.onclick = () => {
        if (++jailbreakClickCount >= 3) {
          f().then(resolve);
        }
      };
    });
  } else {
    return f();
  }
}

const pageContent = () => html`
  <div class="container">
    <div style="display: flex; justify-content: space-evenly; width: 100%">
      ${warningIcon}
      <h1>Men At Work</h1>
      <span data-action="jailbreak">👷</span>
    </div>
    <p style="margin: auto;"><strong>migrating, nothing to see here</strong></p>
  </div>
`;
