@echo off
cd /d "%~dp0"

glslc shader.vert -o shader.vert.spv
glslc shader.frag -o shader.frag.spv