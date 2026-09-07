# 🌊 Infinite Ocean Shader Handover & Architecture Guide (인수 인계서)

본 문서는 **Godot Simple Sky** 프로젝트를 이어받아 **무한 바다(Infinite Ocean) 쉐이더**를 개발할 다음 AI 엔지니어 및 개발자를 위한 기술 인수인계 문서입니다.
현재 구축된 **벤치마크 하네스, 물리 기반 대기/구름 파이프라인, 그리고 60 FPS 성능 골든크로스(MX450 기준)**를 100% 유지하면서 매끄럽게 바다를 구현할 수 있도록 핵심 아키텍처와 인터페이스를 상세히 정리하였습니다.

---

## 1. 프로젝트 기본 정보 및 환경

| 항목 | 스펙 / 설정값 | 비고 |
| :--- | :--- | :--- |
| **Engine** | Godot Engine **v4.7.2.stable.official** | Forward+ 렌더러 (D3D12 / Vulkan) |
| **타깃 하드웨어** | NVIDIA GeForce MX450 (2GB VRAM, 저전력 노트북 GPU) | 성능 벤치마크 기준점 |
| **목표 성능 (Golden Cross)** | **50 ~ 60 FPS** (1080p 해상도, Medium 모드 기준) | 프레임 드랍 억제 필수 |
| **원격 저장소** | `https://github.com/rlsl0422/godot-simple-sky.git` | 브랜치: `main` |
| **루트 프로젝트 디렉터리** | `gd-cshader/` (`project.godot` 위치) | Git 루트 디렉터리 |

---

## 2. 핵심 좌표계 및 스케일 시스템 (World vs Shader Space)

하늘과 대기는 지구 곡률을 반영하기 위해 **킬로미터(km)** 단위의 구체 공간을 사용하며, 고도와 카메라 좌표는 다음과 같이 매핑됩니다:

1. **Godot 월드 공간 (World Space)**:
   - 단위: **미터(Meter)**, Y-Up 좌표계.
   - 바닥(해수면 기준): $Y = 0.0\text{ m}$.
   - 카메라 최저 고도: 지면 통과 방지를 위해 $Y \ge 2.0\text{ m}$로 클램핑됨 (`camera_controller.gd`).
   - 구름 밑면 고도: $Y \approx 1,500\text{ m} \sim 4,000\text{ m}$.

2. **쉐이더 내부 공간 (Kilometer Space, Planet Sphere)**:
   - 단위: **킬로미터(km)**.
   - 지구 반지름: `const float R_EARTH = 6371.0;`
   - 대기 상한: `const float R_ATMOSPHERE = 6471.0;` (두께 100 km)
   - 구름 층: `r_bottom_km = R_EARTH + 1.5;`, `r_top_km = R_EARTH + 4.0;`
   - 카메라 위치 변환:
     ```glsl
     float safe_cam_alt = max(camera_world_position.y, 2.0) * 0.001;
     vec3 camera_pos_km = vec3(camera_world_position.x * 0.001, R_EARTH + safe_cam_alt, camera_world_position.z * 0.001);
     ```
   - **지평선 침하각(Horizon Dip)**:
     고도 $h$에 따른 기하학적 지평선 각도 $\theta_{\text{dip}} \approx -\sqrt{\frac{2h}{R_{\text{EARTH}}}}$가 쉐이더에서 실시간 계산되어, 지평선 아래로 빛이 급격히 끊기거나 줄무늬가 생기는 현상을 원천 방지하고 있습니다.

---

## 3. 대기 & 구름 쉐이더와의 인터페이스 (`atmosphere_clouds.gdshader`)

바다 쉐이더는 대기와 구름으로부터 **빛과 환경 정보**를 전달받아야 사실적인 반사와 굴절을 연출할 수 있습니다.

### 1) 컨트롤러에서 전달되는 주요 유니폼 (Uniforms)
* `sun_direction` (`vec3`): 정규화된 태양 방향 벡터 (시간에 따라 자동 계산됨).
* `sun_color` (`vec3`): 기본 태양 광원색.
* `sun_intensity` (`float`): 태양 조도 (일반적으로 `20.0 ~ 28.0`).
* `atmosphere_density` (`float`): 대기 밀도 계수 (`1.0`).
* `ground_color` (`vec3`): 현재 설정된 지표면 알베도 (`Color(0.18, 0.22, 0.20)`).

### 2) 대기 산란 및 태양광 계산 함수 (`compute_atmosphere`)
```glsl
void compute_atmosphere(vec3 eye_pos_km, vec3 ray_dir, vec3 sun_dir, out vec3 sky_color, out vec3 sun_light_color)
```
- `sky_color`: 레일리/미/오존 산란이 적분된 하늘색 (지평선 방향 클램핑 적용됨).
- `sun_light_color`: 대기 투과 후 지표면에 도달하는 감쇠된 직사 태양광 에너지.

### 3) 톤 매핑 파이프라인
- ACES Film (`tonemap_mode == 1`, 권장 기본값), Reinhard Extended (`mode == 2`), Filmic (`mode == 3`), Linear (`mode == 0`).
- 바다 표면의 하이라이트(스펙큘러)도 톤 매퍼를 통과해야 태양광 부근에서 흰색으로 타지 않고 필름 특유의 롤오프를 얻습니다.

---

## 4. 무한 바다 쉐이더 구현을 위한 두 가지 아키텍처 비교

바다를 구현할 때 다음 두 가지 방법 중 프로젝트 요구사항에 맞춰 선택할 수 있습니다:

### 옵션 A. 스카이 쉐이더 내장 방식 (Meshless Sky Raymarching) — **추천 (단일 패스)**
* **개념**: 별도의 3D 메쉬 없이 현재 `atmosphere_clouds.gdshader`의 `hit_ground` 분기 안에서 해수면을 직접 렌더링.
* **원리**:
  1. `ray_sphere_intersect(camera_pos_km, ray_dir, R_EARTH, t_ground_0, t_ground_1)`로 해수면 교차점 $P$ 계산.
  2. $P$의 월드 좌표($P_{xz}$)와 `TIME`을 기반으로 **Gerstner Wave (4~6파수)** 또는 **프리베이크된 해수면 노멀맵 2장 스크롤 블렌딩**을 통해 해수면 법선 벡터 $N$ 생성.
  3. 반사 벡터 $R = \text{reflect}(\text{ray\_dir}, N)$를 구하고, $R$ 방향의 `sky_color`를 샘플링하여 프레넬(Fresnel) 반사 합성.
  4. 태양 스펙큘러: GGX/블린-퐁으로 $N, \text{sun\_dir}, \text{ray\_dir}$ 하이라이트 계산.
  5. 심해 흡수(Beer-Lambert): 바다 고유의 심해색(`vec3(0.01, 0.05, 0.08)`)과 산란광 합성.
  6. 공중 원근감: 기존 `g_haze` 및 `horizon_factor`를 그대로 거쳐 원경 바다가 지평선 하늘에 완벽히 블렌딩됨.
* **장점**:
  - 추가 Draw Call 0회, 메쉬 관리 불필요, 지평선과 1픽셀의 오차도 없이 100% 완벽 결합.
  - 별도의 깊이 버퍼 버그나 원경 Z-파이팅(Z-fighting)이 원천 발생하지 않음.

### 옵션 B. 기하학적 프로젝티드 그리드 / 클립맵 방식 (Projected Grid Mesh)
* **개념**: 카메라를 따라다니는 고밀도 원형 평면 메쉬(또는 CDLOD Clipmap Plane)를 $Y = 0$에 배치하고 공간 쉐이더(`shader_type spatial`) 적용.
* **장점**:
  - 버텍스 변위(Displacement)를 통해 파도의 기하학적 높낮이(실제 파도 융기) 표현 가능.
  - 해안선, 섬, 오브젝트와의 깊이 버퍼 연동(`DEPTH_TEXTURE`) 및 연안 포말(Foam) 구현 용이.
* **주의사항**:
  - 지평선 끝부분이 스카이 쉐이더의 `R_EARTH` 곡률과 정확히 일치해야 경계선 틈새(Seam)가 생기지 않음.
  - 카메라가 수천 미터 상공으로 올라갈 때 메쉬 외곽 클리핑 거리(Camera Far plane) 관리 필요.

---

## 5. 바다 표면 물리 모델 필수 수식 가이드

바다 쉐이더를 작성할 때 반드시 포함해야 할 물리 수식입니다:

### 1) 프레넬 반사율 (Schlick's Approximation)
물과 공기의 굴절률($n_1 = 1.0, n_2 = 1.333$)에 따른 수직 반사율 $F_0 \approx 0.02$:
```glsl
float fresnel = F0 + (1.0 - F0) * pow(clamp(1.0 - dot(N, V), 0.0, 1.0), 5.0);
```

### 2) 파도 노멀 생성 (Gerstner Waves 예시)
성능을 위해 4~6개의 파수를 합산하거나, 거리에 따른 LOD(원경에서는 노멀맵 단순화)를 적용:
```glsl
// 파수 k, 진폭 A, 속도 c, 방향 D
// w_i = k * dot(D, pos.xz) - c * TIME
// x += D.x * (A * cos(w_i)), z += D.y * (A * cos(w_i)), y += A * sin(w_i)
```

### 3) 태양 경면광 (Sun Specular, Microfacet GGX)
```glsl
vec3 H = normalize(sun_dir + V);
float NdotH = clamp(dot(N, H), 0.0, 1.0);
float roughness = 0.15; // 바다 표면 거칠기
float alpha2 = roughness * roughness;
float D = alpha2 / (PI * pow(NdotH * NdotH * (alpha2 - 1.0) + 1.0, 2.0));
vec3 specular = sun_light_color * D * fresnel;
```

### 4) 코슈미더 공중 원근법 (Koschmieder Aerial Perspective)
기존 대기 시스템과 일관성을 유지하기 위해 바다 표면 출력 시 반드시 적용:
```glsl
float g_haze = clamp(1.0 - exp(-t_ocean_dist * 0.04 * atmosphere_density), 0.0, 1.0);
float horizon_factor = smoothstep(horizon_dip - 0.025, horizon_dip + 0.002, ray_dir.y);
float total_haze = max(g_haze, horizon_factor);
vec3 final_ocean = mix(ocean_shaded_color, sky_color, total_haze);
```

---

## 6. 테스트 및 검증 파이프라인 유지 방법

본 프로젝트는 무인 자동 검증을 위한 **벤치마크 하네스**를 포함하고 있습니다.

### 1) 자동 벤치마크 실행 명령어
Godot 실행 시 콘솔에서 아래와 같이 실행하면 5개 페이즈(추후 바다 페이즈 추가 가능)를 자동으로 순회하고 스크린샷 및 성능 JSON을 저장한 뒤 종료합니다:
```bash
# Windows PowerShell 기준
cd gd-cshader
..\Godot_v4.7.2-stable_win64_console.exe --path . -- --benchmark --quit-after-benchmark
```
* **주의**: 인자 전달 시 반드시 `--` 뒤에 `--benchmark`를 넘겨야 Godot 4 엔진 인자와 유저 스크립트 인자가 분리되어 정상 인식됩니다.
* **타이머 안전 규칙**: AI 에이전트가 백그라운드 프로세스를 실행할 때는 언제나 `schedule` 툴을 사용해 안전 타이머(20~30초)를 먼저 설정해야 무한 대기를 방지할 수 있습니다.

### 2) 하네스에 바다 전용 페이즈 추가 가이드 (`benchmark_harness.gd`)
기존 5개 페이즈 뒤에 6번째 페이즈로 **바다 조망 시나리오**를 추가하여 자동 회귀 테스트를 수행하십시오:
```gdscript
# benchmark_harness.gd 예시
func _setup_phase_6_ocean_view() -> void:
    print("[BenchmarkHarness] Phase 6: Ocean Wave & Specular Reflection test...")
    controller.weather_preset = CloudController.WeatherPreset.GOLDEN_HOUR
    controller.time_of_day = 17.5 # 수면에 길게 늘어지는 태양 하이라이트 검증
    camera.global_position = Vector3(0.0, 15.0, 0.0) # 해수면 15m 상공
    var look_dir = Vector3(0.0, -0.15, -1.0).normalized()
    camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)
```

### 3) 캡처 산출물 경로
- 스크린샷: `screenshots/01_noon_cumulus.png` ~ `05_ground_and_contour_fix.png` (신규: `06_infinite_ocean.png`)
- 성능 지표: `screenshots/perf_metrics.json`
  - `avg_fps`, `avg_frame_time_ms`, `percentile_1_low_fps` 기록됨.

---

## 7. 성능 제약 및 최적화 원칙 (Golden Cross)

* **성능 한계선**: GeForce MX450에서 평균 FPS가 **45 FPS 미만**으로 떨어지지 않아야 합니다.
* **텍스처 페칭 절약**:
  - 대기 10스텝 + 구름 최대 28스텝이 이미 실행 중이므로, 바다 쉐이딩에서는 노멀 텍스처 조회를 최대 2~3회 이내로 제한하거나 수학적 저비용 함수를 활용하십시오.
* **거리별 분기 (Distance Fade)**:
  - 카메라로부터 5km 이상 떨어진 원경 바다는 복잡한 파도 노멀을 평탄화(Flat normal) 처리하여 지평선 스파클(Sparkle aliasing) 및 연산 낭비를 방지하십시오.

---

## 8. Git 작업 및 인계 체크리스트

다음 에이전트가 작업을 진행할 때 준수해야 할 절차입니다:

- [ ] 작업 전 `git status`로 깨끗한 상태 확인 (`main` 브랜치)
- [ ] 쉐이더/스크립트 수정 후 `-- --benchmark`로 성능 지표 및 비주얼 회귀 테스트 수행
- [ ] `.godot/` 캐시 폴더 및 임시 파일이 스테이징되지 않도록 주의 (`.gitignore` 적용 상태)
- [ ] 작업 완료 후 의미 있는 커밋 메시지와 함께 `git push origin main` 실행

본 인수인계서의 가이드를 바탕으로, 멋지고 눈부신 무한 바다를 완성해주시기 바랍니다! 🚀
