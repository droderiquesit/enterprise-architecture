import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { loadConfig } from './config';
import { initRum, waitForRumSession } from './rum';
import './styles.css';

async function start() {
  const root = createRoot(document.getElementById('root')!);
  try {
    const config = await loadConfig(); // config first, then RUM, then the app
    const rumEnabled = initRum(config);
    if (rumEnabled) await waitForRumSession();
    root.render(
      <StrictMode>
        <App config={config} rumEnabled={rumEnabled} />
      </StrictMode>,
    );
  } catch (err) {
    root.render(
      <p role="alert" className="error">
        Configuration error: {err instanceof Error ? err.message : String(err)}
      </p>,
    );
  }
}

void start();
