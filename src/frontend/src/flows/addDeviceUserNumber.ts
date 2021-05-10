import { blobFromUint8Array, blobToHex, derBlobFromBlob } from "@dfinity/agent";
import { WebAuthnIdentity } from "@dfinity/identity";
import { html, render } from "lit-html";
import { displayError } from "../components/displayError";
import { IIConnection } from "../utils/iiConnection";
import { parseUserNumber, setUserNumber } from "../utils/userNumber";
import { displayAddDeviceLink } from "./displayAddDeviceLink";

const pageContent = (userNumber: bigint | null) => html`
  <div class="container">
    <h1>New device</h1>
    <p>Please provide your user number.</p>
    <input
      type="text"
      id="addDeviceUserNumber"
      placeholder="Enter User Number"
      value=${userNumber ?? ""}
    />
    <button id="addDeviceUserNumberContinue" class="primary">Continue</button>
  </div>
`;

export const addDeviceUserNumber = async (
  userNumber: bigint | null
): Promise<void> => {
  const container = document.getElementById("pageContent") as HTMLElement;
  render(pageContent(userNumber), container);
  return init();
};

const init = () => {
  const addDeviceUserNumberContinue = document.getElementById(
    "addDeviceUserNumberContinue"
  ) as HTMLButtonElement;
  const userNumberInput = document.getElementById(
    "addDeviceUserNumber"
  ) as HTMLInputElement;

  userNumberInput.onkeypress = (e) => {
    // submit if user hits enter
    if (e.key === "Enter") {
      e.preventDefault();
      addDeviceUserNumberContinue.click();
    }
  };

  addDeviceUserNumberContinue.onclick = async () => {
    let loginInterval: number;

    const userNumber = parseUserNumber(userNumberInput.value);
    if (userNumber !== null) {
      userNumberInput.classList.toggle("errored", false);
      let identity: WebAuthnIdentity;
      try {
        identity = await WebAuthnIdentity.create();
      } catch (error) {
        await displayError({
          title: "Failed to authenticate",
          message:
            "We failed to collect the necessary information from your security device.",
          detail: error.message,
          primaryButton: "Try again",
        });
        return addDeviceUserNumber(userNumber);
      }
      const publicKey = identity.getPublicKey().toDer();
      const rawId = blobToHex(identity.rawId);

      const url = new URL(location.toString());
      url.pathname = "/";
      url.hash = `#device=${userNumber};${blobToHex(publicKey)};${rawId}`;
      const link = encodeURI(url.toString());

      displayAddDeviceLink(link);
      loginInterval = window.setInterval(async () => {
        console.log("checking if authenticated");
        try {
          const devices = await IIConnection.lookup(userNumber);
          const matchedDevice = devices.find((deviceData) =>
            derBlobFromBlob(
              blobFromUint8Array(Buffer.from(deviceData.pubkey))
            ).equals(publicKey)
          );
          if (matchedDevice !== undefined) {
            window.clearInterval(loginInterval);
            setUserNumber(userNumber);
            window.location.reload();
          }
        } catch (error) {
          console.error(error);
        }
      }, 2500);
    } else {
      userNumberInput.classList.toggle("errored", true);
      userNumberInput.placeholder = "Please enter your User Number first";
    }
  };
};
