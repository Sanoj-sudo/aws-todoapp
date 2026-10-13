# AWS Three-Tier Todo App

A todo app with signup and login, built to test an AWS three-tier architecture.

```
                Internet
                   │
          ┌────────▼────────┐   public subnets
          │  Public ALB :80 │
          └────────┬────────┘
          ┌────────▼────────┐
 WEB TIER │ EC2 + Nginx     │  serves frontend/, proxies /api/* ──┐
          └─────────────────┘                                    │
          ┌──────────────────┐  private subnets                  │
          │ Internal ALB :80 │◄──────────────────────────────────┘
          └────────┬─────────┘
          ┌────────▼────────┐
 APP TIER │ EC2 + Node.js   │  REST API on :4000 (auth + todos)
          └────────┬────────┘
          ┌────────▼────────┐  private DB subnets
 DB TIER  │ RDS MySQL :3306 │  tables: users, todos
          └─────────────────┘
```

| Folder      | Tier     | What it is |
|-------------|----------|------------|
| `frontend/` | Web      | Static HTML/CSS/JS + Nginx config (`nginx.conf.template`) |
| `backend/`  | App      | Node.js/Express API: signup/login (bcrypt + JWT) and per-user todos |
| `database/` | Database | `schema.sql` for MySQL / RDS |
| `scripts/`  | —        | EC2 user-data scripts for the web and app tiers |

The footer of the page shows which web instance, app instance and AZ served
each request, so you can see load balancing and failover working.

## API

| Method | Path                | Auth | Description |
|--------|---------------------|------|-------------|
| GET    | `/health`           | no   | ALB health check (no DB call) |
| GET    | `/api/health`       | no   | App + DB connectivity status |
| POST   | `/api/auth/signup`  | no   | `{name, email, password}` → `{token, user}` |
| POST   | `/api/auth/login`   | no   | `{email, password}` → `{token, user}` |
| GET    | `/api/auth/me`      | yes  | Current user |
| GET    | `/api/todos`        | yes  | List my todos |
| POST   | `/api/todos`        | yes  | `{title}` |
| PUT    | `/api/todos/:id`    | yes  | `{title?, completed?}` |
| DELETE | `/api/todos/:id`    | yes  | Delete a todo |

Auth = header `Authorization: Bearer <token>`.

## 1. Test locally (optional)

```bash
docker compose up --build
# open http://localhost:8080
```

## 2. Deploy to AWS

### Network
1. **VPC** with 2 AZs. In each AZ: 1 public subnet, 1 private app subnet, 1 private DB subnet.
2. **Internet Gateway** for the public subnets, and a **NAT Gateway** so the private app subnets can download packages.

### Security groups
| SG            | Inbound rule |
|---------------|--------------|
| `public-alb-sg`   | 80 (and 443) from `0.0.0.0/0` |
| `web-sg`          | 80 from `public-alb-sg` |
| `internal-alb-sg` | 80 from `web-sg` |
| `app-sg`          | 4000 from `internal-alb-sg` |
| `db-sg`           | 3306 from `app-sg` |

### Database tier
1. Create a **DB subnet group** from the private DB subnets.
2. Create **RDS MySQL 8** in that subnet group with `db-sg`, not publicly accessible. Initial database name: `appdb`.
3. Tables are created automatically when the API starts. You can also run
   `mysql -h <rds-endpoint> -u admin -p < database/schema.sql` from an app instance.

### Upload the code to S3
```bash
aws s3 mb s3://my-three-tier-app-bucket
aws s3 cp frontend/ s3://my-three-tier-app-bucket/frontend/ --recursive
aws s3 cp backend/  s3://my-three-tier-app-bucket/backend/  --recursive --exclude "node_modules/*"
```
Create an **IAM role** for EC2 with read access to that bucket (e.g. `AmazonS3ReadOnlyAccess`).
Add `AmazonSSMManagedInstanceCore` too, so you can connect with Session Manager without SSH keys.

### App tier
1. Edit `scripts/app-tier-userdata.sh`: `S3_BUCKET`, `DB_HOST` (RDS endpoint), `DB_USER`, `DB_PASSWORD`, `JWT_SECRET` (`openssl rand -hex 32`).
2. Create a **launch template**: Amazon Linux 2023, the IAM role, `app-sg`, and the script as user data.
3. Create a **target group**: HTTP port 4000, health check path `/health`.
4. Create an **internal ALB** in the private app subnets with `internal-alb-sg`, listener 80 → that target group.
5. Create an **Auto Scaling group** (min 2) in the private app subnets with this launch template and target group.

### Web tier
1. Edit `scripts/web-tier-userdata.sh`: `S3_BUCKET` and `BACKEND_URL` = `http://<internal-ALB-DNS-name>`.
2. Create a **launch template**: Amazon Linux 2023, the IAM role, `web-sg`, and the script as user data.
3. Create a **target group**: HTTP port 80, health check path `/health`.
4. Create an **internet-facing ALB** in the public subnets with `public-alb-sg`, listener 80 → that target group.
5. Create an **Auto Scaling group** (min 2) in the public subnets with this launch template and target group.

### Test it
Open `http://<public-ALB-DNS-name>`, sign up, and add some todos. Then:
- Refresh several times. The footer should show different web and app instance IDs.
- Terminate an app instance. The app keeps working and the ASG replaces the instance.
- Log in from another browser. Your todos are there, because they're stored in RDS.

## Troubleshooting
| Symptom | Check |
|---------|-------|
| Page loads, footer says "App: unreachable" | `BACKEND_URL` in the web user-data; `internal-alb-sg` allows 80 from `web-sg`; app target group is healthy |
| "DB: error: connect ETIMEDOUT" | `db-sg` allows 3306 from `app-sg`; `DB_HOST` is correct |
| "Access denied for user" | `DB_USER` / `DB_PASSWORD` |
| Logged out when you refresh | `JWT_SECRET` is different on different app instances |
| App instance never becomes healthy | NAT Gateway route; logs with `sudo journalctl -u app` and `/var/log/cloud-init-output.log` |

## Security notes (this is a demo)
- Store `DB_PASSWORD` and `JWT_SECRET` in **Secrets Manager** or **SSM Parameter Store** rather than in user data.
- Add HTTPS on the public ALB with an ACM certificate.
- Use a least-privilege MySQL user instead of the RDS master user (see the end of `schema.sql`).
