@echo off
cd /d "%~dp0"

glslc --target-env=vulkan1.3 shader.vert -o shader.vert.spv
glslc --target-env=vulkan1.3 shader.frag -o shader.frag.spv