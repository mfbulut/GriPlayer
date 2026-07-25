@echo off
echo Compiling Shaders...
glslc shader.vert -o shader.vert.spv
glslc shader.frag -o shader.frag.spv
echo Done!
