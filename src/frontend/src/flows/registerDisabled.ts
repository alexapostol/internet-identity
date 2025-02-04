import { html, render } from "lit-html";
import { warnBox } from "../components/warnBox";

const pageContent = html`
  <div class="l-container c-card c-card--highlight">
    <h1>Create a new Internet Identity Anchor</h1>
    ${warnBox({
      title: "Registration Disabled",
      message: html`<p>
          You are <b>not</b> browsing this website on the expected URL:
          <a href="https://identity.ic0.app">https://identity.ic0.app</a>. For
          security reasons creation of new Internet Identity anchors is disabled
          on this origin.
        </p>
        <p>
          Please switch to
          <a href="https://identity.ic0.app">https://identity.ic0.app</a> to
          register a new Internet Identity anchor.
        </p>
        <p>
          If you were redirected here by another website, please inform the
          developers. More information is provided
          <a
            href="https://forum.dfinity.org/t/internet-identity-proposal-to-deprecate-account-creation-on-all-origins-other-than-https-identity-ic0-app/9760"
            >here</a
          >.
        </p>`,
    })}
    <button id="deviceAliasCancel">Cancel</button>
  </div>
`;

export const registerDisabled = async (): Promise<null> => {
  const container = document.getElementById("pageContent") as HTMLElement;
  render(pageContent, container);
  return init();
};

const init = (): Promise<null> =>
  new Promise((resolve) => {
    const deviceAliasCancel = document.getElementById(
      "deviceAliasCancel"
    ) as HTMLButtonElement;
    deviceAliasCancel.onclick = () => {
      resolve(null);
    };
  });
