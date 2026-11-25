/*
Copyright 2020 the Velero contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package actions

import (
	"context"
	"encoding/json"

	"github.com/cockroachdb/errors"
	"github.com/sirupsen/logrus"
	corev1api "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	velerov1api "github.com/velero-io/velero/pkg/apis/velero/v1"
	velerov2alpha1 "github.com/velero-io/velero/pkg/apis/velero/v2alpha1"
	veleroclient "github.com/velero-io/velero/pkg/client"
	"github.com/velero-io/velero/pkg/label"
	"github.com/velero-io/velero/pkg/plugin/velero"
)

type DataUploadRetrieveAction struct {
	logger logrus.FieldLogger
	client client.Client
}

func NewDataUploadRetrieveAction(logger logrus.FieldLogger, client client.Client) *DataUploadRetrieveAction {
	return &DataUploadRetrieveAction{
		logger: logger,
		client: client,
	}
}

func (d *DataUploadRetrieveAction) AppliesTo() (velero.ResourceSelector, error) {
	return velero.ResourceSelector{
		IncludedResources: []string{"datauploads.velero.io"},
	}, nil
}

func (d *DataUploadRetrieveAction) Execute(input *velero.RestoreItemActionExecuteInput) (*velero.RestoreItemActionExecuteOutput, error) {
	d.logger.Info("Executing DataUploadRetrieveAction")

	dataUpload := velerov2alpha1.DataUpload{}
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(input.ItemFromBackup.UnstructuredContent(), &dataUpload); err != nil {
		d.logger.Errorf("unable to convert unstructured item to DataUpload: %s", err.Error())
		return nil, errors.Wrap(err, "unable to convert unstructured item to DataUpload.")
	}

	backup := &velerov1api.Backup{}
	err := d.client.Get(context.Background(), types.NamespacedName{
		Namespace: input.Restore.Namespace,
		Name:      input.Restore.Spec.BackupName,
	}, backup)
	if err != nil {
		d.logger.WithError(err).Errorf("Fail to get backup for restore %s.", input.Restore.Name)
		return nil, errors.Wrapf(err, "error to get backup for restore %s", input.Restore.Name)
	}

	// 归档中的 DU CR 可能来自其它历史备份：DU CR 完成后常驻 velero 命名空间（供数据卷
	// 明细等消费），namespace-'*' 备份会把它们全部收入归档。结果 CM 按 restore-uid +
	// 源 PVC 标签做唯一性匹配（getDataUploadResult 要求恰好一个），非本备份的 DU 若也
	// 生成结果 CM，同一 PVC 会命中多个 → "multiple DataUpload result cms found" 阻断
	// 恢复；更糟的是仅剩一个时可能错配旧备份快照，静默恢复出错误时点的数据。
	// 因此只认本次恢复源备份自己的 DU（backup-uid 精确比对，防止同名备份重建），
	// 其余 DU 跳过且不创建结果 CM。
	if dataUpload.Labels[velerov1api.BackupUIDLabel] != string(backup.UID) {
		d.logger.Infof("Skipping DataUpload %s/%s of backup %s: not the restore source backup %s",
			dataUpload.Namespace, dataUpload.Name,
			dataUpload.Labels[velerov1api.BackupNameLabel], input.Restore.Spec.BackupName)
		return &velero.RestoreItemActionExecuteOutput{
			SkipRestore: true,
		}, nil
	}

	dataUploadResult := velerov2alpha1.DataUploadResult{
		BackupStorageLocation: backup.Spec.StorageLocation,
		DataMover:             dataUpload.Spec.DataMover,
		SnapshotID:            dataUpload.Status.SnapshotID,
		SnapshotSize:          dataUpload.Status.Progress.TotalBytes,
		SourceNamespace:       dataUpload.Spec.SourceNamespace,
		DataMoverResult:       dataUpload.Status.DataMoverResult,
		NodeOS:                dataUpload.Status.NodeOS,
		FSType:                dataUpload.Spec.SourceFSType,
	}
	if dataUpload.Spec.CSISnapshot != nil {
		dataUploadResult.SnapshotClass = dataUpload.Spec.CSISnapshot.SnapshotClass
	}

	jsonBytes, err := json.Marshal(dataUploadResult)
	if err != nil {
		d.logger.Errorf("fail to convert DataUploadResult to JSON: %s", err.Error())
		return nil, errors.Wrap(err, "fail to convert DataUploadResult to JSON")
	}

	cm := corev1api.ConfigMap{
		TypeMeta: metav1.TypeMeta{
			Kind:       "ConfigMap",
			APIVersion: corev1api.SchemeGroupVersion.String(),
		},
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: dataUpload.Name + "-",
			Namespace:    input.Restore.Namespace,
			Labels: map[string]string{
				velerov1api.RestoreUIDLabel:       label.GetValidName(string(input.Restore.UID)),
				velerov1api.PVCNamespaceNameLabel: label.GetValidName(dataUpload.Spec.SourceNamespace + "." + dataUpload.Spec.SourcePVC),
				velerov1api.ResourceUsageLabel:    label.GetValidName(string(velerov1api.VeleroResourceUsageDataUploadResult)),
			},
		},
		Data: map[string]string{
			string(input.Restore.UID): string(jsonBytes),
		},
	}

	// Dry-run restores must not create the DataUploadResult ConfigMap.
	if input.Restore.Spec.DryRun {
		d.logger.Info("Dry run restore: skipping DataUploadResult ConfigMap creation")
		return &velero.RestoreItemActionExecuteOutput{
			SkipRestore: true,
		}, nil
	}

	err = veleroclient.CreateRetryGenerateName(d.client, context.Background(), &cm)
	if err != nil {
		d.logger.Errorf("fail to create DataUploadResult ConfigMap %s/%s: %s", cm.Namespace, cm.Name, err.Error())
		return nil, errors.Wrap(err, "fail to create DataUploadResult ConfigMap")
	}

	return &velero.RestoreItemActionExecuteOutput{
		SkipRestore: true,
	}, nil
}
