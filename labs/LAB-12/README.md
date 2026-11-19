# LAB-12 — Terraform ile GKE, GitHub Actions ile Deploy

## Amaç

NovaShop altyapısını Google Cloud üzerinde Terraform ile kurmak ve GitHub Actions pipeline'ı ile `ui` ve `catalog` image'larını derleyip GKE'ye deploy etmek. Pipeline GCP'ye uzun ömürlü anahtar yerine Workload Identity Federation ile bağlanır.

## Ön Koşullar

- Billing açık bir GCP projesi ve bu projede `Owner` (veya eşdeğer) yetki.
- Bu reponun kendi GitHub hesabınızdaki kopyası (fork) ve repoda Settings erişimi.
- Yerelde: `gcloud`, `terraform` (1.5+), `kubectl`, `gke-gcloud-auth-plugin`, `git`. İsteğe bağlı: `gh`.

Araçların kurulu olduğunu kontrol edin:

```bash
gcloud version && terraform version && kubectl version --client
```

`gke-gcloud-auth-plugin` yoksa kurun:

```bash
gcloud components install gke-gcloud-auth-plugin
```

## Mimari ve Çalışma Modeli

```mermaid
graph LR
    GH[GitHub Actions] -->|OIDC token| WIF[Workload Identity Federation]
    WIF -->|service account| AR[Artifact Registry<br/>ui, catalog image]
    WIF -->|kubectl apply| GKE[GKE cluster<br/>zonal, 2 x e2-medium spot]
    AR -->|image pull| GKE
    User([curl / tarayıcı]) -->|LoadBalancer :80| GKE
```

<details>
<summary><strong>Dizin yapısı ve çalışma modeli</strong></summary>

```text
labs/LAB-12/
├── terraform/
│   ├── versions.tf               # provider'lar ve GCS backend
│   ├── main.tf                   # API'ler ve modül çağrıları
│   ├── variables.tf / outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── network/              # VPC + subnet (pod ve service aralıkları)
│       ├── gke/                  # zonal cluster + node pool + node service account
│       ├── artifact-registry/    # Docker reposu
│       └── iam-wif/              # Workload Identity pool, provider, deployer service account
└── k8s/                          # namespace, catalog ve ui manifestleri
.github/workflows/lab12-gke.yml   # build → push → deploy → smoke test
```

- Terraform altyapıyı yerelden kurar; state GCS bucket'ında durur.
- Pipeline GitHub'ın OIDC token'ını WIF üzerinden kısa ömürlü GCP kimliğine çevirir. WIF sadece `terraform.tfvars` içindeki `github_repo` reposundan gelen token'ları kabul eder.
- Image'lar commit SHA'sı ile etiketlenip Artifact Registry'ye gönderilir, manifestlerdeki `UI_IMAGE` / `CATALOG_IMAGE` yerine bu etiket yazılarak GKE'ye uygulanır.

</details>

## Adım Adım Uygulama Rehberi

### 1. GCP oturumu

Hem `gcloud` hem Terraform için oturum açın:

```bash
gcloud auth login
gcloud auth application-default login
```

Çalışılacak projeyi seçin (`<PROJECT_ID>` yerine kendi proje ID'niz):

```bash
gcloud config set project <PROJECT_ID>
```

### 2. Terraform state için GCS bucket

State dosyası bu bucket'ta tutulur; bucket adı tüm GCS içinde benzersiz olmalıdır ([GCS backend](https://developer.hashicorp.com/terraform/language/backend/gcs)):

```bash
gcloud storage buckets create gs://<PROJECT_ID>-tfstate --location europe-west1 --uniform-bucket-level-access
```

State dosyasının eski sürümleri saklansın diye versioning açın:

```bash
gcloud storage buckets update gs://<PROJECT_ID>-tfstate --versioning
```

### 3. Değişken dosyası

Örnek dosyayı kopyalayın:

```bash
cd labs/LAB-12/terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` içinde `project_id` ve `github_repo` (`kullanici/novashop-lab`) değerlerini düzenleyin:

```hcl
project_id  = "<PROJECT_ID>"
github_repo = "<GITHUB_KULLANICI>/novashop-lab"
```

### 4. Terraform ile kurulum

Kullanılan kaynaklar: [Google provider 8.12.0](https://registry.terraform.io/providers/hashicorp/google/8.12.0/docs) · [container_cluster](https://registry.terraform.io/providers/hashicorp/google/8.12.0/docs/resources/container_cluster) · [container_node_pool](https://registry.terraform.io/providers/hashicorp/google/8.12.0/docs/resources/container_node_pool) · [artifact_registry_repository](https://registry.terraform.io/providers/hashicorp/google/8.12.0/docs/resources/artifact_registry_repository) · [iam_workload_identity_pool_provider](https://registry.terraform.io/providers/hashicorp/google/8.12.0/docs/resources/iam_workload_identity_pool_provider)

Provider'ları indirin ve backend'i bucket'a bağlayın (*beklenen:* `Terraform has been successfully initialized!`):

```bash
terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
```

Oluşturulacak kaynakları listeleyin (*beklenen:* `Plan: 25 to add, 0 to change, 0 to destroy.`):

```bash
terraform plan -out=tfplan
```

Kaynakları oluşturun; GKE cluster ile birlikte yaklaşık 10 dakika sürer:

```bash
terraform apply tfplan
```

<details>
<summary><strong>Beklenen çıktı</strong></summary>

```text
Apply complete! Resources: 25 added, 0 changed, 0 destroyed.

Outputs:

artifact_registry_url = "europe-west1-docker.pkg.dev/<PROJECT_ID>/novashop"
artifact_repository = "novashop"
cluster_name = "novashop-gke"
project_id = "<PROJECT_ID>"
region = "europe-west1"
service_account_email = "novashop-github-deployer@<PROJECT_ID>.iam.gserviceaccount.com"
workload_identity_provider = "projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-xxxx/providers/github"
zone = "europe-west1-b"
```

</details>

Kodla canlı altyapının aynı olduğunu kontrol edin (*beklenen:* `No changes. Your infrastructure matches the configuration.`):

```bash
terraform plan
```

### 5. GitHub Secrets ve Variables

Değerler Terraform çıktılarından alınır ([GitHub Actions secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)):

| Ad | Tür | Değeri veren komut |
|---|---|---|
| `GCP_PROJECT_ID` | Secret | `terraform output -raw project_id` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Secret | `terraform output -raw workload_identity_provider` |
| `GCP_SERVICE_ACCOUNT` | Secret | `terraform output -raw service_account_email` |
| `GCP_REGION` | Variable | `terraform output -raw region` |
| `GCP_ZONE` | Variable | `terraform output -raw zone` |
| `GKE_CLUSTER` | Variable | `terraform output -raw cluster_name` |
| `GAR_REPOSITORY` | Variable | `terraform output -raw artifact_repository` |

1. GitHub'da reponuzu açın, üst menüden **Settings**'e tıklayın.
2. Sol menüde **Secrets and variables > Actions**'ı açın.
3. **Secrets** sekmesinde **New repository secret**: **Name** = tablodaki ad, **Secret** = ilgili komutun çıktısı, **Add secret**. Üç secret için tekrarlayın.
4. **Variables** sekmesinde **New repository variable**: **Name** ve **Value** tablodaki gibi, **Add variable**. Dört variable için tekrarlayın.

<details>
<summary><strong>Aynı işlem gh CLI ile</strong></summary>

`terraform/` dizininde çalıştırın (`<REPO>` = `kullanici/novashop-lab`); değerler ekrana yazılmadan GitHub'a gönderilir:

```bash
terraform output -raw project_id                 | gh secret set GCP_PROJECT_ID -R <REPO>
terraform output -raw workload_identity_provider | gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER -R <REPO>
terraform output -raw service_account_email      | gh secret set GCP_SERVICE_ACCOUNT -R <REPO>
gh variable set GCP_REGION     -R <REPO> --body "$(terraform output -raw region)"
gh variable set GCP_ZONE       -R <REPO> --body "$(terraform output -raw zone)"
gh variable set GKE_CLUSTER    -R <REPO> --body "$(terraform output -raw cluster_name)"
gh variable set GAR_REPOSITORY -R <REPO> --body "$(terraform output -raw artifact_repository)"
```

Girilen adları kontrol edin (değerler gösterilmez):

```bash
gh secret list -R <REPO> && gh variable list -R <REPO>
```

</details>

### 6. Pipeline'ı çalıştırma

Pipeline `main` dalına `labs/LAB-12/k8s/`, `src/ui/`, `src/catalog/` veya workflow dosyasında değişiklik push edildiğinde başlar. Elle başlatmak için **Actions > LAB-12 - NovaShop GKE Deploy > Run workflow** ya da ([auth](https://github.com/google-github-actions/auth), [get-gke-credentials](https://github.com/google-github-actions/get-gke-credentials) action'ları kullanılır):

```bash
gh workflow run lab12-gke.yml -R <REPO>
```

Son koşuyu takip edin; üç job (`Build & Push (ui)`, `Build & Push (catalog)`, `Deploy to GKE`) yeşil bitmelidir (ilk koşu yaklaşık 6-8 dakika):

```bash
gh run watch -R <REPO> $(gh run list -R <REPO> -w lab12-gke.yml -L 1 --json databaseId --jq '.[0].databaseId')
```

`Deploy to GKE` job'ının **Smoke test** adımında beklenen çıktı:

```text
UI adresi: http://<EXTERNAL_IP>
{"status":"UP","groups":["liveness","readiness"]}
Ana sayfa HTTP 200
```

### 7. Doğrulama

`kubectl`'i cluster'a bağlayın:

```bash
gcloud container clusters get-credentials novashop-gke --zone europe-west1-b
```

Node'ların `Ready` olduğunu kontrol edin:

```bash
kubectl get nodes
```

<details>
<summary><strong>Beklenen çıktı</strong></summary>

```text
NAME                                           STATUS   ROLES    AGE   VERSION
gke-novashop-gke-novashop-pool-xxxxxxxx-xxxx   Ready    <none>   7m    v1.36.4-gke.2377000
gke-novashop-gke-novashop-pool-xxxxxxxx-xxxx   Ready    <none>   7m    v1.36.4-gke.2377000
```

</details>

Pod'ları ve servisleri listeleyin; pod'lar `Running`, `ui` servisinin `EXTERNAL-IP` değeri uygulamanın adresidir:

```bash
kubectl -n novashop get pods,svc
```

<details>
<summary><strong>Beklenen çıktı</strong></summary>

```text
NAME                           READY   STATUS    RESTARTS   AGE
pod/catalog-xxxxxxxxxx-xxxxx   1/1     Running   0          90s
pod/ui-xxxxxxxxxx-xxxxx        1/1     Running   0          89s

NAME              TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
service/catalog   ClusterIP      10.30.x.x      <none>          80/TCP         90s
service/ui        LoadBalancer   10.30.x.x      <EXTERNAL_IP>   80:3xxxx/TCP   88s
```

</details>

Uygulamanın sağlık durumunu dışarıdan sorgulayın (*beklenen:* `{"status":"UP","groups":["liveness","readiness"]}`):

```bash
IP=$(kubectl -n novashop get svc ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://$IP/actuator/health
```

Katalog sayfasının `catalog` servisinden ürün getirdiğini kontrol edin (*beklenen:* `0`'dan büyük bir sayı, ör. `6`). Tarayıcıda `http://<EXTERNAL_IP>` adresinden mağaza açılır:

```bash
curl -s "http://$IP/catalog?page=1" | grep -c 'href="/catalog/'
```

Image'ların Artifact Registry'ye gittiğini kontrol edin (*beklenen:* `.../novashop/ui` ve `.../novashop/catalog` satırları):

```bash
gcloud artifacts docker images list europe-west1-docker.pkg.dev/<PROJECT_ID>/novashop
```

## Temizlik

Önce uygulama namespace'ini silin; böylece Terraform dışında oluşan LoadBalancer da kalkar:

```bash
kubectl delete namespace novashop
```

Terraform ile oluşturulan tüm kaynakları silin (`terraform/` dizininde, *beklenen:* `Destroy complete! Resources: 25 destroyed.`):

```bash
terraform destroy
```

State bucket'ını da silmek isterseniz:

```bash
gcloud storage rm --recursive gs://<PROJECT_ID>-tfstate
```
