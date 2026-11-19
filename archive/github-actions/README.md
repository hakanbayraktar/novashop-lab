# Arşivlenmiş GitHub Actions workflow'ları

Bu klasördeki workflow örnekleri eğitimde incelenmek üzere korunur; GitHub Actions yalnız `.github/workflows/` yolunu çalıştırdığı için burada bulunan dosyalar tetiklenmez.

Aktif workflow'lar yalnız LAB-12'ninkilerdir:

- `LAB-12 - 00 GCP Hazırlık (Bootstrap)`
- `LAB-12 - 01 GKE Altyapısı (Terraform)`
- `LAB-12 - 02 NovaShop GKE Uygulama Dağıtımı`
- `LAB-12 - 03 GKE Monitoring & Logging Dağıtımı`

EC2, ECS, Docker Hub, eski CI, E2E ve release örnekleri bu klasöre taşınmıştır. Yeniden kullanmak isterseniz dosyayı `.github/workflows/` altına geri alıp gerekli secret ve variable değerlerini tanımlayın.
