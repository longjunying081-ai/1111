function ExcavatorTracker_Enhanced()
    % =========================================================================
    % 矿车追踪系统 v11.0 (增强版)
    % 新增功能：
    %   1. 暂停/恢复功能
    %   2. 实时性能监控（FPS、处理时间、置信度）
    %   3. 数据可视化导出（轨迹、速度、位移、统计）
    % =========================================================================
    
    % --- 1. 变量初始化 ---
    CP = []; 
    tform = [];
    historyData = []; 
    lastValidCentroid = []; 
    squareSize = 50; 
    roiLimit = 150; 
    
    % 卡尔曼滤波变量
    kf_X = zeros(4, 1); 
    kf_P = eye(4) * 100; 
    kf_Q = diag([1, 1, 10, 10]); 
    kf_R = diag([20, 20]); 
    kf_H = [1 0 0 0; 0 1 0 0]; 
    
    % 视频处理状态
    isPaused = false;
    isProcessing = false;
    historyIdx = 0;
    
    % 性能监控变量
    frameCount = 0;
    fpsTimer = tic;
    processingTimes = [];
    trackConfidences = [];
    
    % 日志文件
    logFile = [];
    fid = [];
    
    % --- 2. 加载相机参数 ---
    try
        data = load('cameraParams8.mat'); 
        fNames = fieldnames(data);
        for i = 1:length(fNames)
            tempObj = data.(fNames{i});
            if isa(tempObj, 'cameraParameters') || isa(tempObj, 'cameraIntrinsics')
                CP = tempObj; break;
            elseif isprop(tempObj, 'CameraParameters')
                CP = tempObj.CameraParameters; break;
            end
        end
    catch
        errordlg('加载内参文件失败'); return;
    end

    % --- 3. UI 界面设计 ---
    fig = uifigure('Name', '小车追踪系统 v11.0 (增强版)', ...
        'Position', [100 100 1400 850], ...
        'CloseRequestFcn', @(~,~) cleanupAndClose());
    
    % 主网格布局
    gl = uigridlayout(fig, [3, 2]);
    gl.ColumnWidth = {'2x', 380}; 
    gl.RowHeight = {'1x', 150, 200};
    gl.Padding = [10 10 10 10];
    
    % --- 左侧：视频显示 ---
    ax = uiaxes(gl); 
    ax.Layout.Row = 1; 
    ax.Layout.Column = 1;
    ax.Title.String = '实时视频处理画面';
    
    % --- 右侧上方：控制面板 ---
    ctrlPanel = uipanel(gl, 'Title', '控制面板', 'FontWeight', 'bold');
    ctrlPanel.Layout.Row = 1; 
    ctrlPanel.Layout.Column = 2;
    ctrlPanelGrid = uigridlayout(ctrlPanel, [6, 2]);
    ctrlPanelGrid.ColumnWidth = {100, 150};
    ctrlPanelGrid.RowHeight = repmat({35}, 1, 6);
    ctrlPanelGrid.Padding = [10 10 10 10];
    
    % 按钮组
    btnRun = uibutton(ctrlPanelGrid, 'push', 'Text', '🚀 开始处理', ...
        'BackgroundColor', [0.1 0.45 0.7], 'FontColor', 'white', 'FontWeight', 'bold');
    btnRun.Layout.Row = 1; btnRun.Layout.Column = [1 2];
    
    btnPause = uibutton(ctrlPanelGrid, 'push', 'Text', '⏸️ 暂停', ...
        'BackgroundColor', [0.8 0.6 0.1], 'FontColor', 'white', 'Enable', 'off');
    btnPause.Layout.Row = 2; btnPause.Layout.Column = 1;
    
    btnResume = uibutton(ctrlPanelGrid, 'push', 'Text', '▶️ 继续', ...
        'BackgroundColor', [0.1 0.7 0.4], 'FontColor', 'white', 'Enable', 'off');
    btnResume.Layout.Row = 2; btnResume.Layout.Column = 2;
    
    btnExport = uibutton(ctrlPanelGrid, 'push', 'Text', '📥 导出数据', ...
        'BackgroundColor', [0.5 0.2 0.7], 'FontColor', 'white', 'Enable', 'off');
    btnExport.Layout.Row = 3; btnExport.Layout.Column = 1;
    
    btnVisualize = uibutton(ctrlPanelGrid, 'push', 'Text', '📊 数据可视化', ...
        'BackgroundColor', [0.2 0.5 0.8], 'FontColor', 'white', 'Enable', 'off');
    btnVisualize.Layout.Row = 3; btnVisualize.Layout.Column = 2;
    
    % 显示字段
    uilabel(ctrlPanelGrid, 'Text', 'X (mm):'); 
    xField = uieditfield(ctrlPanelGrid, 'numeric', 'Editable', 'off');
    xField.Layout.Row = 4; xField.Layout.Column = 2;
    
    uilabel(ctrlPanelGrid, 'Text', 'Y (mm):'); 
    yField = uieditfield(ctrlPanelGrid, 'numeric', 'Editable', 'off');
    yField.Layout.Row = 5; yField.Layout.Column = 2;
    
    uilabel(ctrlPanelGrid, 'Text', '速度 (mm/s):'); 
    speedField = uieditfield(ctrlPanelGrid, 'numeric', 'Editable', 'off');
    speedField.Layout.Row = 6; speedField.Layout.Column = 2;
    
    % --- 右侧中方：性能监控 ---
    perfPanel = uipanel(gl, 'Title', '性能监控', 'FontWeight', 'bold');
    perfPanel.Layout.Row = 2; 
    perfPanel.Layout.Column = 2;
    perfPanelGrid = uigridlayout(perfPanel, [3, 2]);
    perfPanelGrid.ColumnWidth = {100, 150};
    perfPanelGrid.RowHeight = repmat({35}, 1, 3);
    perfPanelGrid.Padding = [10 10 10 10];
    
    uilabel(perfPanelGrid, 'Text', '实时 FPS:', 'FontWeight', 'bold');
    fpsLabel = uilabel(perfPanelGrid, 'Text', '0.0', 'FontColor', [0.1 0.7 0.1], 'FontWeight', 'bold');
    fpsLabel.Layout.Row = 1; fpsLabel.Layout.Column = 2;
    
    uilabel(perfPanelGrid, 'Text', '处理时间:', 'FontWeight', 'bold');
    procTimeLabel = uilabel(perfPanelGrid, 'Text', '0.0 ms', 'FontColor', [0.8 0.4 0.1], 'FontWeight', 'bold');
    procTimeLabel.Layout.Row = 2; procTimeLabel.Layout.Column = 2;
    
    uilabel(perfPanelGrid, 'Text', '追踪置信度:', 'FontWeight', 'bold');
    confLabel = uilabel(perfPanelGrid, 'Text', '0%', 'FontColor', [0.1 0.45 0.7], 'FontWeight', 'bold');
    confLabel.Layout.Row = 3; confLabel.Layout.Column = 2;
    
    % --- 右侧下方：日志区域 ---
    logPanel = uipanel(gl, 'Title', '日志输出', 'FontWeight', 'bold');
    logPanel.Layout.Row = 3; 
    logPanel.Layout.Column = 2;
    logArea = uitextarea(logPanel, 'Editable', 'off', 'FontFamily', 'Courier', 'FontSize', 9);
    logArea.Position = [0 0 380 200];
    
    % --- 左下：追踪轨迹 ---
    trackAx = uiaxes(gl); 
    trackAx.Layout.Row = [2 3]; 
    trackAx.Layout.Column = 1;
    trackAx.Title.String = '轨迹图';
    grid(trackAx, 'on'); 
    hold(trackAx, 'on');
    
    % 初始化日志
    initializeLog();
    logMessage('系统已启动，等待用户操作', 'INFO');
    
    % 按钮回调
    btnRun.ButtonPushedFcn = @(~,~) mainWorkflow();
    btnPause.ButtonPushedFcn = @(~,~) pauseVideo();
    btnResume.ButtonPushedFcn = @(~,~) resumeVideo();
    btnExport.ButtonPushedFcn = @(~,~) exportDataToExcel();
    btnVisualize.ButtonPushedFcn = @(~,~) visualizeData();

    %% ===== 4. 核心工作流 =====
    function mainWorkflow()
        % 地面标定图处理
        [cFile, cPath] = uigetfile({'*.jpg;*.png;*.bmp'}, '1. 选择地面标定图片');
        if isequal(cFile, 0), return; end
        
        logMessage(sprintf('加载标定图: %s', cFile), 'INFO');
        rawCalib = imread(fullfile(cPath, cFile));
        
        CP = syncCameraParams(CP, rawCalib);
        calibImg = undistortImage(rawCalib, CP);
        [imagePoints, boardSize] = detectCheckerboardPoints(calibImg);
        
        if isempty(imagePoints)
            logMessage('标定图中未发现棋盘格', 'ERROR');
            uialert(fig, '标定图中未发现棋盘格', '错误');
            return;
        end
        
        tform = fitgeotrans(double(imagePoints), ...
            double(generateCheckerboardPoints(boardSize, squareSize)), 'projective');
        logMessage('棋盘格检测完成，已生成透视变换矩阵', 'INFO');
        
        % 视频处理
        [vFile, vPath] = uigetfile({'*.mp4;*.avi;*.mov'}, '2. 选择运行视频');
        if isequal(vFile, 0), return; end
        
        logMessage(sprintf('加载视频: %s', vFile), 'INFO');
        v = VideoReader(fullfile(vPath, vFile));
        
        % 初始化
        isProcessing = true;
        isPaused = false;
        historyIdx = 0;
        frameCount = 0;
        processingTimes = [];
        trackConfidences = [];
        
        % 预分配历史数据
        maxFrames = min(10000, round(v.FrameRate * 300));  % 最多5分钟
        historyData = zeros(maxFrames, 4);
        
        % 更新按钮状态
        btnRun.Enable = 'off';
        btnPause.Enable = 'on';
        btnResume.Enable = 'off';
        btnExport.Enable = 'off';
        btnVisualize.Enable = 'off';
        
        % 清空轨迹图
        cla(trackAx);
        hTrack = animatedline(trackAx, 'Color', 'r', 'LineWidth', 2.5, 'Marker', 'o', 'MarkerSize', 3);
        
        % 循环处理视频帧
        frameIdx = 0;
        lastUpdateTime = tic;
        lastValidCentroid = [];
        kf_X = zeros(4, 1);
        kf_P = eye(4) * 100;
        
        while hasFrame(v) && isProcessing
            % 暂停处理
            if isPaused
                pause(0.1);
                continue;
            end
            
            % 读取帧
            procStart = tic;
            rawFrame = readFrame(v);
            frameIdx = frameIdx + 1;
            
            % 计算精确的帧时间
            currTime = (frameIdx - 1) / v.FrameRate;
            
            % 同步相机参数
            CP = syncCameraParams(CP, rawFrame);
            frame = undistortImage(rawFrame, CP);
            
            % ===== 红色特征提取 =====
            R = double(frame(:,:,1));
            G = double(frame(:,:,2));
            B = double(frame(:,:,3));
            
            redFeature = (R - G > 35) & (R - B > 35);
            bw = imclose(imopen(redFeature, strel('disk', 2)), strel('disk', 6));
            
            % ===== 目标检测与追踪 =====
            stats = regionprops(bw, 'Centroid', 'Area', 'Circularity');
            confidence = 0;  % 追踪置信度
            
            if ~isempty(stats)
                validIdx = find([stats.Area] > 150 & [stats.Circularity] > 0.4);
                
                if ~isempty(validIdx)
                    allCentroids = reshape([stats(validIdx).Centroid], 2, [])';
                    
                    if isempty(lastValidCentroid)
                        [~, maxIdx] = max([stats(validIdx).Area]);
                        pixelPos = allCentroids(maxIdx, :);
                        confidence = 0.5;
                    else
                        dists = sqrt(sum((allCentroids - lastValidCentroid).^2, 2));
                        inRange = find(dists < roiLimit);
                        
                        if ~isempty(inRange)
                            [~, subIdx] = min(dists(inRange));
                            pixelPos = allCentroids(inRange(subIdx), :);
                            % 置信度与距离反相关
                            confidence = max(0.3, 1 - dists(inRange(subIdx)) / roiLimit);
                        else
                            confidence = 0.1;  % 丢失追踪，置信度降低
                            pixelPos = [];
                        end
                    end
                    
                    if ~isempty(pixelPos)
                        lastValidCentroid = pixelPos;
                        
                        % 坐标转换
                        worldPos = transformPointsForward(tform, pixelPos);
                        obs_X = worldPos(1);
                        obs_Y = worldPos(2);
                        
                        % Kalman 滤波更新
                        if historyIdx == 0
                            kf_X = [obs_X; obs_Y; 0; 0];
                            kf_wX = obs_X;
                            kf_wY = obs_Y;
                            speed = 0;
                        else
                            dt = currTime - historyData(historyIdx, 1);
                            if dt > 0.001  % 防止除以零
                                A = [1 0 dt 0; 0 1 0 dt; 0 0 1 0; 0 0 0 1];
                                X_pred = A * kf_X;
                                P_pred = A * kf_P * A' + kf_Q;
                                K = P_pred * kf_H' / (kf_H * P_pred * kf_H' + kf_R);
                                kf_X = X_pred + K * ([obs_X; obs_Y] - kf_H * X_pred);
                                kf_P = (eye(4) - K * kf_H) * P_pred;
                                kf_wX = kf_X(1);
                                kf_wY = kf_X(2);
                                speed = norm([kf_X(3), kf_X(4)]);
                            else
                                kf_wX = obs_X;
                                kf_wY = obs_Y;
                                speed = historyData(historyIdx, 4);
                            end
                        end
                        
                        % 更新 UI
                        xField.Value = kf_wX;
                        yField.Value = kf_wY;
                        speedField.Value = speed;
                        
                        % 保存历史数据
                        historyIdx = historyIdx + 1;
                        if historyIdx > size(historyData, 1)
                            historyData = [historyData; zeros(round(size(historyData, 1)*0.5), 4)];
                        end
                        historyData(historyIdx, :) = [currTime, kf_wX, kf_wY, speed];
                        
                        % 绘制轨迹
                        addpoints(hTrack, kf_wX, kf_wY);
                        
                        % 标记目标
                        frame = insertMarker(frame, pixelPos, '*', 'Color', 'yellow', 'Size', 15);
                    end
                end
            end
            
            % 显示处理后的视频帧
            imshow(frame, 'Parent', ax);
            
            % ===== 性能监控更新 =====
            procTime = toc(procStart) * 1000;  % 转换为毫秒
            processingTimes = [processingTimes, procTime];
            trackConfidences = [trackConfidences, confidence];
            frameCount = frameCount + 1;
            
            % 每秒更新一次性能指标
            if toc(lastUpdateTime) > 1
                if frameCount > 0
                    avgFps = frameCount / toc(lastUpdateTime);
                    avgProcTime = mean(processingTimes(end-frameCount+1:end));
                    avgConfidence = mean(trackConfidences(end-frameCount+1:end)) * 100;
                    
                    fpsLabel.Text = sprintf('%.1f FPS', avgFps);
                    procTimeLabel.Text = sprintf('%.1f ms', avgProcTime);
                    confLabel.Text = sprintf('%.1f%%', avgConfidence);
                end
                frameCount = 0;
                lastUpdateTime = tic;
            end
            
            drawnow limitrate;
        end
        
        % 处理完成
        isProcessing = false;
        btnRun.Enable = 'on';
        btnPause.Enable = 'off';
        btnResume.Enable = 'off';
        btnExport.Enable = 'on';
        btnVisualize.Enable = 'on';
        
        % 截取有效数据
        historyData = historyData(1:historyIdx, :);
        
        logMessage(sprintf('视频处理完成，共处理 %d 帧', historyIdx), 'INFO');
    end

    %% ===== 5. 暂停功能 =====
    function pauseVideo()
        isPaused = true;
        btnPause.Enable = 'off';
        btnResume.Enable = 'on';
        logMessage('⏸️ 视频已暂停', 'INFO');
    end

    %% ===== 6. 继续功能 =====
    function resumeVideo()
        isPaused = false;
        btnPause.Enable = 'on';
        btnResume.Enable = 'off';
        logMessage('▶️ 视频已继续', 'INFO');
    end

    %% ===== 7. 导出数据到 Excel =====
    function exportDataToExcel()
        if isempty(historyData) || size(historyData, 1) == 0
            uialert(fig, '没有可导出的数据', '提示');
            return;
        end
        
        [file, path] = uiputfile({'*.xlsx', 'Excel 文件'; '*.csv', 'CSV 文件'}, ...
            '保存数据文件', 'TrackResult_Enhanced.xlsx');
        
        if isequal(file, 0), return; end
        
        try
            T = table(historyData(:,1), historyData(:,2), historyData(:,3), historyData(:,4), ...
                'VariableNames', {'Time_s', 'X_mm', 'Y_mm', 'Speed_mm_s'});
            writetable(T, fullfile(path, file));
            logMessage(sprintf('数据已导出: %s', fullfile(path, file)), 'INFO');
            uialert(fig, sprintf('数据已成功导出至:\n%s', fullfile(path, file)), '成功');
        catch ME
            logMessage(sprintf('导出失败: %s', ME.message), 'ERROR');
            uialert(fig, sprintf('导出失败:\n%s', ME.message), '错误');
        end
    end

    %% ===== 8. 数据可视化导出 =====
    function visualizeData()
        if isempty(historyData) || size(historyData, 1) < 2
            uialert(fig, '数据不足，无法生成可视化', '提示');
            return;
        end
        
        try
            logMessage('正在生成可视化图表...', 'INFO');
            
            % 创建新图表窗口
            figVis = figure('Name', '追踪数据分析', 'NumberTitle', 'off', ...
                'Position', [200 200 1200 800]);
            
            % 提取数据
            time = historyData(:, 1);
            x = historyData(:, 2);
            y = historyData(:, 3);
            speed = historyData(:, 4);
            
            % ===== 子图1：二维轨迹 =====
            subplot(2, 3, 1);
            plot(x, y, 'b.-', 'LineWidth', 1.5, 'MarkerSize', 4);
            xlabel('X 坐标 (mm)', 'FontSize', 10, 'FontWeight', 'bold');
            ylabel('Y 坐标 (mm)', 'FontSize', 10, 'FontWeight', 'bold');
            title('二维追踪轨迹', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            axis equal;
            
            % 添加起点和终点标记
            plot(x(1), y(1), 'go', 'MarkerSize', 10, 'MarkerFaceColor', 'g', 'DisplayName', '起点');
            plot(x(end), y(end), 'r*', 'MarkerSize', 15, 'DisplayName', '终点');
            legend;
            
            % ===== 子图2：速度曲线 =====
            subplot(2, 3, 2);
            plot(time, speed, 'r-', 'LineWidth', 1.5);
            xlabel('时间 (s)', 'FontSize', 10, 'FontWeight', 'bold');
            ylabel('速度 (mm/s)', 'FontSize', 10, 'FontWeight', 'bold');
            title('速度随时间变化', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            
            % 平均速度线
            hold on;
            avgSpeed = mean(speed);
            plot(time, ones(size(time)) * avgSpeed, 'g--', 'LineWidth', 2, ...
                'DisplayName', sprintf('平均速度: %.1f mm/s', avgSpeed));
            legend;
            
            % ===== 子图3：位置随时间变化 =====
            subplot(2, 3, 3);
            plot(time, x, 'b-', 'LineWidth', 1.5, 'DisplayName', 'X 坐标');
            hold on;
            plot(time, y, 'r-', 'LineWidth', 1.5, 'DisplayName', 'Y 坐标');
            xlabel('时间 (s)', 'FontSize', 10, 'FontWeight', 'bold');
            ylabel('坐标 (mm)', 'FontSize', 10, 'FontWeight', 'bold');
            title('X/Y 坐标随时间变化', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            legend;
            
            % ===== 子图4：单帧位移 =====
            subplot(2, 3, 4);
            displacement = sqrt(diff(x).^2 + diff(y).^2);
            plot(time(1:end-1), displacement, 'g-', 'LineWidth', 1.5);
            xlabel('时间 (s)', 'FontSize', 10, 'FontWeight', 'bold');
            ylabel('位移 (mm)', 'FontSize', 10, 'FontWeight', 'bold');
            title('单帧位移量', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            
            % ===== 子图5：速度分布直方图 =====
            subplot(2, 3, 5);
            histogram(speed, 30, 'FaceColor', [0.1 0.45 0.7], 'EdgeColor', 'black');
            xlabel('速度 (mm/s)', 'FontSize', 10, 'FontWeight', 'bold');
            ylabel('频数', 'FontSize', 10, 'FontWeight', 'bold');
            title('速度分布直方图', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            
            % ===== 子图6：统计信息 =====
            subplot(2, 3, 6);
            axis off;
            
            totalDist = sum(displacement);
            avgSpeed = mean(speed);
            maxSpeed = max(speed);
            minSpeed = min(speed);
            totalTime = time(end) - time(1);
            
            statsText = sprintf(['== 轨迹统计信息 ==\n\n' ...
                '总时长: %.2f s\n' ...
                '总距离: %.1f mm\n' ...
                '平均速度: %.1f mm/s\n' ...
                '最大速度: %.1f mm/s\n' ...
                '最小速度: %.1f mm/s\n' ...
                '总帧数: %d\n' ...
                '采样率: %.1f fps\n\n' ...
                '起点: (%.1f, %.1f) mm\n' ...
                '终点: (%.1f, %.1f) mm\n' ...
                '直线距离: %.1f mm'], ...
                totalTime, totalDist, avgSpeed, maxSpeed, minSpeed, ...
                length(time), length(time)/totalTime, ...
                x(1), y(1), x(end), y(end), ...
                sqrt((x(end)-x(1))^2 + (y(end)-y(1))^2));
            
            text(0.1, 0.5, statsText, 'FontSize', 11, 'FontFamily', 'Courier', ...
                'BackgroundColor', [0.95 0.95 0.95], 'EdgeColor', 'black', ...
                'Padding', 10, 'VerticalAlignment', 'middle');
            
            % 保存图表
            [file, path] = uiputfile({'*.png', 'PNG 文件'; '*.pdf', 'PDF 文件'; ...
                '*.fig', 'MATLAB Figure'}, '保存可视化图表', 'TrackVisualization.png');
            
            if ~isequal(file, 0)
                saveas(figVis, fullfile(path, file));
                logMessage(sprintf('可视化图表已保存: %s', fullfile(path, file)), 'INFO');
                uialert(fig, sprintf('图表已成功保存至:\n%s', fullfile(path, file)), '成功');
            end
            
        catch ME
            logMessage(sprintf('可视化失败: %s', ME.message), 'ERROR');
            uialert(fig, sprintf('可视化失败:\n%s', ME.message), '错误');
        end
    end

    %% ===== 9. 日志管理系统 =====
    function initializeLog()
        logFile = fullfile(tempdir, sprintf('ExcavatorTracker_%s.log', ...
            datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
        fid = fopen(logFile, 'w');
        logMessage('========== 矿车追踪系统启动 ==========', 'SYSTEM');
        logMessage(sprintf('日志文件: %s', logFile), 'SYSTEM');
    end

    function logMessage(msg, level)
        if nargin < 2, level = 'INFO'; end
        
        timestamp = datetime('now', 'Format', 'HH:mm:ss.SSS');
        fullMsg = sprintf('[%s] [%-8s] %s', timestamp, level, msg);
        
        % 写入文件
        if ~isempty(fid)
            fprintf(fid, '%s\n', fullMsg);
            fflush(fid);
        end
        
        % 显示在 UI（保持最后50行）
        currentText = logArea.Value;
        if isempty(currentText)
            logArea.Value = fullMsg;
        else
            logArea.Value = [currentText; fullMsg];
        end
        
        lines = splitlines(logArea.Value);
        if length(lines) > 50
            logArea.Value = lines(end-49:end);
        end
        
        % 控制台输出
        switch level
            case 'ERROR'
                fprintf(2, '%s\n', fullMsg);
            case 'WARNING'
                fprintf('%s\n', fullMsg);
            otherwise
                fprintf('%s\n', fullMsg);
        end
    end

    %% ===== 10. 辅助函数 =====
    function updatedCP = syncCameraParams(oldCP, img)
        imgSize = [size(img, 1), size(img, 2)];
        if isequal(oldCP.ImageSize, imgSize)
            updatedCP = oldCP;
        else
            updatedCP = cameraParameters('IntrinsicMatrix', oldCP.IntrinsicMatrix, ...
                'ImageSize', imgSize, ...
                'RadialDistortion', oldCP.RadialDistortion, ...
                'TangentialDistortion', oldCP.TangentialDistortion);
        end
    end

    function cleanupAndClose()
        logMessage('系统关闭中...', 'SYSTEM');
        isProcessing = false;
        
        if ~isempty(fid)
            fclose(fid);
            logMessage(sprintf('日志已保存至: %s', logFile), 'SYSTEM');
        end
        
        delete(fig);
    end
end
