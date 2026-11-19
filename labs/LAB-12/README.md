# LAB-12 — GKE, Terraform ve GitHub Actions ile NovaShop

## Amaç

NovaShop'u Google Cloud üzerinde çalıştırmak. Altyapı (VPC, GKE cluster, Artifact Registry) Terraform ile **yalnızca GitHub Actions içinden** kurulur ve silinir; uygulama Helm ile, monitoring/logging araçları kubectl ile yine Actions üzerinden dağıtılır. Actions GCP'ye anahtar dosyası olmadan, **Workload Identity Federation (WIF)** ile bağlanır.

Akış üç workflow'dan oluşur:

| Workflow | Dosya | Ne yapar |
|---|---|---|
| `LAB-12 - 01 GKE Altyapısı (Terraform)` | `.github/workflows/lab12-infra.yml` | `plan` / `apply` / `destroy`: VPC, GKE, Artifact Registry ve Traefik ingress controller |
| `LAB-12 - 02 NovaShop GKE Uygulama Dağıtımı` | `.github/workflows/lab12-deploy.yml` | UI testleri, image build, Artifact Registry'ye push, Helm ile 5 mikroservis, smoke test |
| `LAB-12 - 03 GKE Monitoring & Logging Dağıtımı` | `.github/workflows/lab12-monitoring.yml` | ELK 9, Prometheus, Grafana, ortak Ingress, Cloudflare DNS |

## Ön Koşullar

- Billing açık bir GCP projesi ve bu projede `Owner` yetkisi.
- Bu reponun kendi GitHub hesabınızdaki kopyası (fork) ve repoda Settings erişimi.
- Yerelde `gcloud` CLI ve `gh` CLI (`gh auth login` yapılmış). Lokal bağlantı adımı için `kubectl`.
- İsteğe bağlı: alan adı Cloudflare'de olan bir zone (DNS kayıtları için).

## Mimari ve Çalışma Modeli

```mermaid
flowchart LR
    GH["GitHub Actions"] -->|OIDC token| WIF["Workload Identity Federation"]
    WIF -->|service account| TF["01: Terraform"]
    TF --> GKE["GKE cluster<br/>zonal, 2 x e2-standard-2 spot"]
    TF --> AR["Artifact Registry"]
    TF -. state .-> GCS["GCS bucket"]
    WIF --> D["02: Helm deploy"] --> GKE
    D -->|novashop-ui image| AR
    WIF --> M["03: ELK + Prometheus + Grafana"] --> GKE
    U(["Tarayıcı / curl"]) -->|Cloudflare DNS| LB["Traefik LoadBalancer IP"] --> GKE
```

- **Bir kerelik hazırlık** (yerelde gcloud ile): API'ler, Terraform state bucket'ı, GitHub Actions service account'u ve WIF. Bunlar olmadan Actions GCP'ye bağlanamaz, bu yüzden Terraform'un dışındadır.
- **Geri kalan her şey** workflow'larla kurulur ve `01`'in `destroy` seçeneğiyle silinir.

<details>
<summary><strong>Dizin yapısı</strong></summary>

```text
labs/LAB-12/
├── terraform/
│   ├── versions.tf            # google provider, GCS backend
│   ├── variables.tf           # proje, bölge, zone, node tipi/sayısı
│   ├── main.tf                # modül çağrıları
│   ├── outputs.tf             # cluster adı, Artifact Registry adresi
│   └── modules/
│       ├── network/           # VPC + subnet (pod ve service IP aralıkları)
│       ├── gke/               # zonal cluster + spot node pool + node service account
│       └── artifact-registry/ # Docker reposu
├── helm/values-gke.yaml       # charts/novashop için GKE değerleri (Traefik Ingress)
└── monitoring/                # 00-06 ELK, Prometheus, Grafana; 07 Traefik Ingress
```

</details>

<details>
<summary><strong>Terraform modülleri ne yapıyor</strong></summary>

**`versions.tf`**: State dosyası runner'da değil, hazırlıkta açılan GCS bucket'ında durur. Bucket adı workflow'da `-backend-config` ile verilir:

```hcl
backend "gcs" {}
```

**`modules/network`**: Otomatik subnet'siz bir VPC ve tek subnet açar. GKE VPC-native çalıştığı için pod ve service IP'leri subnet'in ikincil aralıklarından gelir:

```hcl
secondary_ip_range {
  range_name    = "pods"
  ip_cidr_range = var.pods_cidr
}
```

**`modules/gke`**: Zonal (tek zone) cluster açar; varsayılan node pool yerine ayrı, yönetilebilir bir node pool kullanır. Node'lar spot (ucuz, kesintiye uğrayabilir) ve en az yetkili ayrı bir service account ile çalışır:

```hcl
resource "google_container_cluster" "this" {
  location            = var.zone
  initial_node_count  = 0
  deletion_protection = false
  ...
}

resource "google_container_node_pool" "default" {
  node_count = var.node_count
  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    service_account = google_service_account.nodes.email
  }
}
```

**`modules/artifact-registry`**: UI image'ının gönderileceği Docker reposu (`<BÖLGE>-docker.pkg.dev/<PROJE_ID>/novashop`).

</details>

## Adım Adım Uygulama Rehberi

### 1. Bir kerelik hazırlık (gcloud)

#### 1.1 Değişkenler

Aşağıdaki komutların hepsi bu değişkenleri kullanır. `<PROJE_ID>` ve `<GITHUB_KULLANICI>/<REPO>` yerine kendi değerlerinizi yazın, diğerlerini olduğu gibi bırakabilirsiniz:

```bash
PROJECT_ID=<PROJE_ID>
REPO=<GITHUB_KULLANICI>/<REPO>
REGION=europe-west1
ZONE=europe-west1-b
CLUSTER_NAME=novashop-training-gke
SA_NAME=novashop-github
POOL_ID=github-pool
PROVIDER_ID=github-provider
TF_STATE_BUCKET=${PROJECT_ID}-tfstate
SA_EMAIL=${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com
```

#### 1.2 Oturum, proje ve API'ler

GCP'ye giriş yapın ve projeyi seçin:

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
```

Terraform ve workflow'ların kullandığı API'leri açın (1-2 dakika sürer):

```bash
gcloud services enable compute.googleapis.com container.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com cloudresourcemanager.googleapis.com storage.googleapis.com
```

*Beklenen çıktı:* `Operation "operations/..." finished successfully.`

#### 1.3 Terraform state bucket'ı

Terraform state'i için bucket oluşturun; ad tüm GCS içinde benzersiz olmalıdır:

```bash
gcloud storage buckets create "gs://${TF_STATE_BUCKET}" --location="$REGION" \
  --uniform-bucket-level-access --public-access-prevention
```

State'in eski sürümleri saklansın diye versioning açın:

```bash
gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
```

#### 1.4 GitHub Actions service account'u ve rolleri

Workflow'ların kullanacağı service account'u oluşturun:

```bash
gcloud iam service-accounts create "$SA_NAME" --display-name="NovaShop GitHub Actions"
```

Altyapıyı kurup silebilmesi ve deploy edebilmesi için proje rollerini verin:

```bash
for ROLE in roles/container.admin roles/compute.networkAdmin roles/artifactregistry.admin \
            roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser \
            roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None --quiet >/dev/null
done
```

| Rol | Neden |
|---|---|
| `roles/container.admin` | GKE cluster'ı kurmak/silmek, Helm ve kubectl ile dağıtım |
| `roles/compute.networkAdmin` | VPC ve subnet |
| `roles/artifactregistry.admin` | Docker reposunu kurmak, image push etmek |
| `roles/iam.serviceAccountAdmin` | Node'lar için ayrı service account oluşturmak |
| `roles/iam.serviceAccountUser` | Node pool'a bu service account'u atamak |
| `roles/resourcemanager.projectIamAdmin` | Node service account'una log/metrik/image okuma rolleri vermek |

State bucket'ına okuma/yazma yetkisi verin (yalnızca bu bucket):

```bash
gcloud storage buckets add-iam-policy-binding "gs://${TF_STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/storage.objectAdmin
```

#### 1.5 Workload Identity Federation

GitHub Actions token'larını kabul edecek pool'u oluşturun:

```bash
gcloud iam workload-identity-pools create "$POOL_ID" --location=global \
  --display-name="GitHub Actions"
```

GitHub OIDC provider'ını ekleyin. `--attribute-condition` yalnızca sizin reponuzdan gelen token'ları kabul eder:

```bash
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --location=global --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '${REPO}'"
```

Reponuzun service account'u kullanabilmesi için `roles/iam.workloadIdentityUser` bağlayın:

```bash
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPO}"
```

### 2. GitHub secret ve variable'ları

Secret'lar loglarda maskelenir; variable'lar düz metindir. Değerler 1. adımdaki değişkenlerden gelir:

| Tür | Ad | Değer nereden gelir |
|---|---|---|
| Secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --location=global --workload-identity-pool="$POOL_ID" --format='value(name)'` |
| Secret | `GCP_SERVICE_ACCOUNT` | `echo "$SA_EMAIL"` |
| Secret (isteğe bağlı) | `CLOUDFLARE_API_TOKEN` | Cloudflare > My Profile > API Tokens > Create Token > "Edit zone DNS" şablonu > Zone Resources: alan adınız |
| Secret (isteğe bağlı) | `CLOUDFLARE_ZONE_ID` | Cloudflare > alan adınız > Overview > sağ sütundaki API bölümü > Zone ID |
| Variable | `GCP_PROJECT_ID` | `echo "$PROJECT_ID"` |
| Variable | `GCP_REGION` | `echo "$REGION"` |
| Variable | `GCP_ZONE` | `echo "$ZONE"` |
| Variable | `GKE_CLUSTER_NAME` | `echo "$CLUSTER_NAME"` |
| Variable | `TF_STATE_BUCKET` | `echo "$TF_STATE_BUCKET"` |
| Variable | `BASE_DOMAIN` | Alan adınız (varsayılan `devopsatolyesi.com`) |

**gh CLI ile** (1. adımdaki terminalde). Secret değerleri ekrana yazılmadan doğrudan GitHub'a gider:

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --location=global \
  --workload-identity-pool="$POOL_ID" --format='value(name)' | gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER -R "$REPO"
printf '%s' "$SA_EMAIL" | gh secret set GCP_SERVICE_ACCOUNT -R "$REPO"
gh variable set GCP_PROJECT_ID   -R "$REPO" --body "$PROJECT_ID"
gh variable set GCP_REGION       -R "$REPO" --body "$REGION"
gh variable set GCP_ZONE         -R "$REPO" --body "$ZONE"
gh variable set GKE_CLUSTER_NAME -R "$REPO" --body "$CLUSTER_NAME"
gh variable set TF_STATE_BUCKET  -R "$REPO" --body "$TF_STATE_BUCKET"
gh variable set BASE_DOMAIN      -R "$REPO" --body "devopsatolyesi.com"
```

Cloudflare kullanacaksanız token ve zone ID'yi girin (komut değeri sorar, yapıştırıp Enter'a basın):

```bash
gh secret set CLOUDFLARE_API_TOKEN -R "$REPO"
gh secret set CLOUDFLARE_ZONE_ID -R "$REPO"
```

Girilen adları kontrol edin (değerler gösterilmez):

```bash
gh secret list -R "$REPO" && gh variable list -R "$REPO"
```

**GitHub arayüzü ile:**

1. Reponuzda **Settings**'e, sol menüde **Secrets and variables > Actions**'a tıklayın.
2. **Secrets** sekmesinde **New repository secret**: **Name** alanına tablodaki adı, **Secret** alanına değeri yazıp **Add secret**'a tıklayın.
3. **Variables** sekmesinde **New repository variable**: **Name** ve **Value** alanlarını doldurup **Add variable**'a tıklayın.

![Settings > Secrets and variables > Actions](images/01-actions-secrets.png)

![New repository secret](images/02-new-secret.png)

![Variables sekmesi](images/03-variables.png)

### 3. Altyapıyı kurma: 01 apply

GitHub'da **Actions > LAB-12 - 01 GKE Altyapısı (Terraform) > Run workflow** ile `action: apply` seçin ya da:

```bash
gh workflow run lab12-infra.yml -R "$REPO" -f action=apply
```

Koşuyu takip edin (ilk kurulum yaklaşık 10-12 dakika):

```bash
gh run watch -R "$REPO" $(gh run list -R "$REPO" -w lab12-infra.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

<details>
<summary><strong>01 workflow'unun adımları</strong></summary>

| Adım | Ne yapar |
|---|---|
| GCP kimlik doğrulaması | GitHub OIDC token'ını WIF ile kısa ömürlü service account kimliğine çevirir |
| Terraform başlat | `terraform init -backend-config="bucket=..." -backend-config="prefix=novashop/lab-12"` |
| Biçim ve doğrulama | `terraform fmt -check` ve `terraform validate` |
| Terraform plan / apply | Plan her seçenekte çalışır; `apply` seçilirse uygulanır |
| GKE kubeconfig oluştur | `gcloud container clusters get-credentials` |
| Traefik ingress controller kur | Tek bir LoadBalancer IP'si açar; uygulama ve monitoring Ingress'leri bunu paylaşır |
| Traefik load balancer'ını kaldır | Yalnızca `destroy`: Terraform dışındaki load balancer'ı siler ki VPC silinebilsin |
| Terraform destroy | Yalnızca `destroy`: tüm altyapıyı siler |

Kimlik doğrulama bloğu (anahtar dosyası yok):

```yaml
- uses: google-github-actions/auth@v3
  with:
    project_id: ${{ vars.GCP_PROJECT_ID }}
    workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
```

</details>

### 4. Uygulamayı dağıtma: 02

**Actions > LAB-12 - 02 NovaShop GKE Uygulama Dağıtımı > Run workflow** ya da:

```bash
gh workflow run lab12-deploy.yml -R "$REPO"
```

Koşuyu takip edin (yaklaşık 6-8 dakika):

```bash
gh run watch -R "$REPO" $(gh run list -R "$REPO" -w lab12-deploy.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

<details>
<summary><strong>02 workflow'unun adımları</strong></summary>

| Adım | Ne yapar |
|---|---|
| Birim testleri | `src/ui` için `./mvnw test` |
| Artifact Registry girişi | `gcloud auth configure-docker <BÖLGE>-docker.pkg.dev` |
| UI image derle ve gönder | `novashop-ui:sha-<commit>` image'ını Artifact Registry'ye push eder |
| Traefik kontrol et / kur | Traefik yoksa kurar |
| Helm ile dağıt | `charts/novashop` + `labs/LAB-12/helm/values-gke.yaml`; ui, catalog, cart, orders, checkout |
| Smoke test | Ingress IP'sine `Host: novashop.<BASE_DOMAIN>` başlığıyla `/actuator/health` ve ana sayfa isteği |

Helm komutu:

```bash
helm upgrade --install novashop charts/novashop \
  --namespace novashop --create-namespace \
  --values labs/LAB-12/helm/values-gke.yaml \
  --set ingress.hosts[0].host="$APP_HOST" \
  --set ui.image.repository="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${GAR_REPOSITORY}/${IMAGE_NAME}" \
  --set ui.image.tag="$IMAGE_TAG" \
  --wait --timeout 10m
```

</details>

### 5. Monitoring ve logging: 03

**Actions > LAB-12 - 03 GKE Monitoring & Logging Dağıtımı > Run workflow** ile `action: apply` ya da:

```bash
gh workflow run lab12-monitoring.yml -R "$REPO" -f action=apply
```

Koşuyu takip edin (yaklaşık 5 dakika):

```bash
gh run watch -R "$REPO" $(gh run list -R "$REPO" -w lab12-monitoring.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

<details>
<summary><strong>03 workflow'unun adımları</strong></summary>

| Adım | Ne yapar |
|---|---|
| Bileşenleri kur | `labs/LAB-12/monitoring/00-07`: Elasticsearch, Kibana, Logstash, Fluent Bit, Prometheus, Grafana ve ortak Ingress |
| Kibana Data View | `k8s-logs-*` veri görünümünü oluşturur |
| Load balancer IP adresini bekle | Traefik servisinin dış IP'sini alır |
| Cloudflare DNS | `novashop`, `elk`, `grafana`, `prometheus` için proxied A kaydı açar/günceller; secret yoksa uyarıyla atlar |
| Smoke test | Her host'a load balancer IP'si üzerinden istek atar |

</details>

### 6. Doğrulama

Workflow özetindeki (Summary) load balancer IP'sini alın ve uygulamayı `Host` başlığıyla sorgulayın:

```bash
curl -s -H "Host: novashop.devopsatolyesi.com" http://<LB_IP>/actuator/health
```

*Beklenen çıktı:* `{"status":"UP","groups":["liveness","readiness"]}`

Cloudflare secret'ları girildiyse alan adı üzerinden:

```bash
curl -s https://novashop.devopsatolyesi.com/actuator/health
```

| Servis | Adres | Kullanıcı / Şifre |
|---|---|---|
| NovaShop | `https://novashop.<BASE_DOMAIN>` | - |
| Grafana | `https://grafana.<BASE_DOMAIN>` | `admin` / `devops2026` |
| Kibana | `https://elk.<BASE_DOMAIN>` | - |
| Prometheus | `https://prometheus.<BASE_DOMAIN>` | - |

### 7. Lokalden GKE'ye bağlanma

`gcloud` kurulu değilse kurun (macOS):

```bash
brew install --cask google-cloud-sdk
```

Diğer işletim sistemleri için: https://cloud.google.com/sdk/docs/install

GCP hesabınızla giriş yapın ve projeyi seçin:

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
```

`kubectl`'in GKE'ye kimlik doğrulaması için gereken eklentiyi kurun:

```bash
gcloud components install gke-gcloud-auth-plugin kubectl
```

Cluster bilgilerini `~/.kube/config`'e yazın:

```bash
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"
```

*Beklenen çıktı:* `kubeconfig entry generated for novashop-training-gke.`

Node'ları listeleyin; iki node `Ready` olmalıdır:

```bash
kubectl get nodes
```

Uygulama ve monitoring pod'larını listeleyin; hepsi `Running` olmalıdır:

```bash
kubectl get pods -n novashop
kubectl get pods -n logging
kubectl get pods -n monitoring
```

Load balancer IP'sini alın ve uygulamaya erişin:

```bash
LB_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -H "Host: novashop.devopsatolyesi.com" "http://${LB_IP}/actuator/health"
```

DNS olmadan tarayıcıdan açmak için uygulamayı lokal porta yönlendirin ve http://localhost:8080 adresini açın:

```bash
kubectl port-forward -n novashop svc/novashop-ui 8080:8080
```

## Temizlik

Altyapıyı workflow ile silin: **Actions > LAB-12 - 01 GKE Altyapısı (Terraform) > Run workflow** ile `action: destroy` ya da:

```bash
gh workflow run lab12-infra.yml -R "$REPO" -f action=destroy
```

Koşunun yeşil bittiğini kontrol edin (yaklaşık 8-10 dakika); cluster listesi boş dönmelidir:

```bash
gh run watch -R "$REPO" $(gh run list -R "$REPO" -w lab12-infra.yml -L 1 --json databaseId --jq '.[0].databaseId')
gcloud container clusters list
```

Lab'ı tamamen bitirdiyseniz bir kerelik hazırlık kaynaklarını da silin (1. adımdaki değişkenler tanımlı olmalı). Önce proje rollerini kaldırın:

```bash
for ROLE in roles/container.admin roles/compute.networkAdmin roles/artifactregistry.admin \
            roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser \
            roles/resourcemanager.projectIamAdmin; do
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None --quiet >/dev/null
done
```

Service account'u, WIF pool'unu ve state bucket'ını silin:

```bash
gcloud iam service-accounts delete "$SA_EMAIL" --quiet
gcloud iam workload-identity-pools delete "$POOL_ID" --location=global --quiet
gcloud storage rm --recursive "gs://${TF_STATE_BUCKET}"
```

Silinen WIF pool'u 30 gün boyunca aynı adla yeniden oluşturulamaz; lab'ı bu süre içinde tekrar kuracaksanız `POOL_ID` için farklı bir ad kullanın.
