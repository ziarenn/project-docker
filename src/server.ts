import express, { Request, Response } from "express";
import sql, { config as SqlConfig } from "mssql";

const app = express();
const PORT: number = Number(process.env.PORT) || 8080;

// Zero Hardcoded Credentials: every secret comes from the environment.
// These variables are injected by Terraform into the App Service app_settings.
const dbConfig: SqlConfig = {
  server: process.env.DB_SERVER as string,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  options: {
    // Azure SQL Database requires an encrypted connection.
    encrypt: true,
    trustServerCertificate: false,
  },
};

function htmlPage(title: string, bodyHtml: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title}</title>
  <style>
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; background: #0f172a; color: #e2e8f0; margin: 0; padding: 2rem; }
    .card { max-width: 760px; margin: 3rem auto; background: #1e293b; border-radius: 16px; padding: 2rem 2.5rem; box-shadow: 0 10px 30px rgba(0,0,0,.4); }
    h1 { margin-top: 0; font-size: 1.6rem; }
    .badge { display: inline-block; padding: .25rem .75rem; border-radius: 999px; font-size: .8rem; font-weight: 600; }
    .ok { background: #064e3b; color: #6ee7b7; }
    .err { background: #7f1d1d; color: #fca5a5; }
    pre { background: #0f172a; padding: 1rem; border-radius: 10px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
    code { color: #93c5fd; }
    footer { margin-top: 1.5rem; font-size: .8rem; color: #94a3b8; }
  </style>
</head>
<body>
  <div class="card">
    ${bodyHtml}
    <footer>IoT App &middot; Azure SQL + ACR + App Service &middot; Zero Hardcoded Credentials</footer>
  </div>
</body>
</html>`;
}

app.get("/", async (_req: Request, res: Response) => {
  // Fail fast with a clear message if the environment is misconfigured.
  const missing = ["DB_SERVER", "DB_NAME", "DB_USER", "DB_PASSWORD"].filter(
    (k) => !process.env[k],
  );
  if (missing.length > 0) {
    return res.status(500).send(
      htmlPage(
        "Configuration error",
        `<h1><span class="badge err">CONFIG ERROR</span></h1>
         <p>Missing required environment variables:</p>
         <pre>${missing.join("\n")}</pre>`,
      ),
    );
  }

  let pool: sql.ConnectionPool | undefined;
  try {
    pool = await sql.connect(dbConfig);
    const result = await pool.request().query("SELECT @@VERSION AS version");
    const version: string = result.recordset[0].version;

    res.send(
      htmlPage(
        "IoT App - DB connected",
        `<h1>IoT Application <span class="badge ok">DB CONNECTED</span></h1>
         <p>Successfully connected to Azure SQL Database and executed <code>SELECT @@VERSION</code>:</p>
         <pre>${version}</pre>`,
      ),
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    res.status(500).send(
      htmlPage(
        "IoT App - DB error",
        `<h1>IoT Application <span class="badge err">DB ERROR</span></h1>
         <p>Failed to connect to or query the database:</p>
         <pre>${message}</pre>`,
      ),
    );
  } finally {
    if (pool) {
      await pool.close();
    }
  }
});

app.get("/health", (_req: Request, res: Response) => {
  res.status(200).send("OK");
});

app.listen(PORT, () => {
  console.log(`IoT app listening on port ${PORT}`);
});
