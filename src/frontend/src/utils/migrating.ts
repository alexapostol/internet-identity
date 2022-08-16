import { displayError } from "../components/displayError";
import { features } from "../features";

/** Run the specified function iff the "IS_MIGRATING" feature is not set.
 **/
export function unlessIsMigrating<T>(f: () => Promise<T>): Promise<T> {
  if (features.IS_MIGRATING) {
    return displayError({
      title: "Men At Work 👷",
      message: "migrating, nothing to see here",
      primaryButton: "Reload",
    }).then(() => {
      window.location.reload();
      return f(); // we never make it here, just make ts happy
    });
  } else {
    return f();
  }
}
