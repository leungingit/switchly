#!/bin/bash
#
# Switchly 构建脚本
# 使用 XcodeGen 生成项目（若已安装），再直接用 xcodebuild 构建并打包。
#
# 提示：Makefile 提供了等价且更细粒度的目标（make bootstrap / make build /
# make test-unit / make zip / make run），日常开发建议优先使用 Makefile。

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
PROJECT_NAME="Switchly"
SCHEME_NAME="Switchly"
APP_NAME="Switchly"
BUILD_DIR="./build"
DERIVED_DATA="./DerivedData"

# 版本号统一以 Resources/Info.plist 为准，避免与硬编码值漂移
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.0.0")

echo -e "${BLUE}🚀 Switchly 构建脚本 v${VERSION}${NC}"
echo "======================================"
echo ""

# 检查是否在正确的目录
if [ ! -f "project.yml" ]; then
    echo -e "${RED}❌ 请在 Switchly 项目根目录运行此脚本${NC}"
    exit 1
fi

# 检查 xcodebuild
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}❌ xcodebuild 未找到，请安装 Xcode${NC}"
    exit 1
fi

# 检查 xcodegen
if command -v xcodegen &> /dev/null; then
    echo -e "${GREEN}✅ 找到 xcodegen${NC}"
    echo -e "${YELLOW}📦 正在生成 Xcode 项目...${NC}"
    xcodegen generate
    echo -e "${GREEN}✅ 项目已生成${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠️ xcodegen 未找到，跳过项目生成${NC}"
    echo -e "${YELLOW}⚠️ 确保 Switchly.xcodeproj 已存在${NC}"
    echo ""
fi

# 检查项目文件
if [ ! -d "${PROJECT_NAME}.xcodeproj" ]; then
    echo -e "${RED}❌ 未找到 ${PROJECT_NAME}.xcodeproj${NC}"
    echo ""
    echo -e "${YELLOW}💡 请运行:${NC}"
    echo "   1. 安装 XcodeGen: brew install xcodegen"
    echo "   2. 生成项目: xcodegen generate"
    exit 1
fi

echo -e "${GREEN}✅ 项目文件已就绪${NC}"
echo ""

# 清理输出目录（只清理产物目录，不删除 DerivedData：
# 删除 DerivedData 会丢掉 SPM 依赖缓存，且一旦构建失败将什么都不剩）
echo -e "${YELLOW}🧹 正在清理旧的构建产物...${NC}"
rm -rf "$BUILD_DIR"
echo -e "${GREEN}✅ 清理完成${NC}"
echo ""

# 构建 Release 版本
echo -e "${YELLOW}🔨 正在构建 Release 版本...${NC}"
# 签名优先级：SIGN_IDENTITY 环境变量 > 本机 Config/Local.xcconfig（若存在，
# 见 Config/Local.xcconfig.example）> Config/Base.xcconfig 默认值（ad-hoc）。
SIGN_OVERRIDE=""
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_OVERRIDE="CODE_SIGN_IDENTITY=${SIGN_IDENTITY}"
elif [[ ! -f Config/Local.xcconfig ]]; then
    SIGN_OVERRIDE="CODE_SIGN_IDENTITY=-"
fi

xcodebuild -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ${SIGN_OVERRIDE:+"$SIGN_OVERRIDE"} \
    -quiet \
    clean build

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ 构建成功！${NC}"
else
    echo -e "${RED}❌ 构建失败${NC}"
    exit 1
fi
echo ""

# 查找构建产物
APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ 未找到构建产物: ${APP_PATH}${NC}"
    exit 1
fi

# 创建输出目录
mkdir -p "$BUILD_DIR"

# 复制应用
echo -e "${YELLOW}📦 正在复制应用...${NC}"
cp -R "$APP_PATH" "$BUILD_DIR/"

echo -e "${GREEN}✅ 应用已复制到 ${BUILD_DIR}/${APP_NAME}.app${NC}"
echo ""

# 打包
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ZIP_NAME="${APP_NAME}_${VERSION}_${TIMESTAMP}.zip"

echo -e "${YELLOW}📦 正在创建压缩包...${NC}"
(cd "$BUILD_DIR" && zip -q -r "$ZIP_NAME" "${APP_NAME}.app")

echo -e "${GREEN}✅ 压缩包已创建: ${BUILD_DIR}/${ZIP_NAME}${NC}"
echo ""

# 显示文件大小
APP_SIZE=$(du -sh "$BUILD_DIR/${APP_NAME}.app" | cut -f1)
ZIP_SIZE=$(du -sh "$BUILD_DIR/$ZIP_NAME" | cut -f1)

echo -e "${BLUE}📊 构建结果${NC}"
echo -e "   应用文件: ${GREEN}${APP_SIZE}${NC}"
echo -e "   压缩包: ${GREEN}${ZIP_SIZE}${NC}"
echo ""

echo -e "${GREEN}🎉 构建完成！${NC}"
echo ""
echo -e "${BLUE}💡 下一步:${NC}"
echo "   1. 测试应用: open ${BUILD_DIR}/${APP_NAME}.app"
echo "   2. 分发应用: ${BUILD_DIR}/${ZIP_NAME}"
echo ""
