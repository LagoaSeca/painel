import subprocess

out = subprocess.run(
    ["dart", "analyze", "lib/core/network/manager_api_service.dart", "lib/features/flyer/presentation/pages/tela_gerenciar_flyers.dart"], 
    capture_output=True, 
    text=True
)
print("STDOUT:", out.stdout)
print("STDERR:", out.stderr)
